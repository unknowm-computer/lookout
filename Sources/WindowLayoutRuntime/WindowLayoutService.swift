import AppKit
import Combine
import WindowLayoutModel
import WindowHelperProtocol

/// Separate from metric sampling: no window polling while idle, and no AX work when disabled.
@MainActor final class WindowLayoutService: ObservableObject {
    typealias Status = WindowLayoutPhase
    @Published private(set) var permission = WindowAccessReport(trustedAPI: false, query: .notChecked)
    @Published private(set) var enabled: Bool
    @Published private(set) var trusted = false
    @Published private(set) var busy = false
    @Published private(set) var status: Status = .disabled
    @Published private(set) var current: WindowLayoutSnapshot?
    @Published private(set) var lastGood: WindowLayoutSnapshot?
    @Published private(set) var restoreReport: WindowRestoreReport?
    @Published private var previewEnabled: Bool
    @Published private var screenRecordingAllowed = false
    @Published private var previewRevision = 0
    private(set) var pending: Bool
    private var restoreRequested: Bool
    var snapshot: WindowLayoutSnapshot? { current ?? lastGood }
    var canRestore: Bool { enabled && trusted && snapshot != nil && !busy }
    private let defaults: UserDefaults
    private let bootSessionID: String?
    private let backend: any WindowLayoutBackend
    private let artifacts: WindowLayoutArtifacts?
    private let now: () -> TimeInterval
    private let step: Duration
    private let attempts: Int
    private var changedAt: TimeInterval
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sleeping = false
    private var previewCapture: Task<[Data], Never>?
    private var observedDisplays: [LayoutDisplay]?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let enabledKey = "windowLayout.enabled.v1"
    static let currentKey = "windowLayout.current.v1"
    static let backupKey = "windowLayout.lastGood.v1"
    static let pendingKey = "windowLayout.pending.v1"
    static let restoreKey = "windowLayout.restoreRequested.v1"
    static let bootSessionKey = "windowLayout.bootSession.v1"
    static let previewKey = "windowLayout.preview.v1"

    init(defaults: UserDefaults = .standard, backend: (any WindowLayoutBackend)? = nil,
         observe: Bool = true, startEnabled: Bool = true, step: Duration = .seconds(1), attempts: Int = 30,
         bootSessionID: String? = WindowBootSession.currentID(),
         artifacts: WindowLayoutArtifacts? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.backend = backend ?? AccessibilityWindowLayoutBackend()
        self.bootSessionID = bootSessionID
        self.artifacts = artifacts
        previewEnabled = defaults.bool(forKey: Self.previewKey)
        self.now = now; self.step = step; self.attempts = attempts; changedAt = now()
        // Old/unscoped snapshots must never be adopted as belonging to this boot.
        // Checking at startup also covers shutdowns where no final notification was delivered.
        if bootSessionID == nil || defaults.string(forKey: Self.bootSessionKey) != bootSessionID {
            for key in [Self.currentKey, Self.backupKey, Self.pendingKey, Self.restoreKey] {
                defaults.removeObject(forKey: key)
            }
            defaults.set(bootSessionID, forKey: Self.bootSessionKey)
        }
        enabled = startEnabled && defaults.bool(forKey: Self.enabledKey)
        current = WindowLayoutSnapshot.decode(defaults.data(forKey: Self.currentKey))
        lastGood = WindowLayoutSnapshot.decode(defaults.data(forKey: Self.backupKey))
        pending = defaults.bool(forKey: Self.pendingKey)
        restoreRequested = defaults.bool(forKey: Self.restoreKey)
        observedDisplays = snapshot?.displays
        artifacts?.retainPreviews(for: previewEnabled ? previewDates : [])
        if snapshot == nil { pending = false; restoreRequested = false }
        if observe { installObservers() }
        if enabled { refresh() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        cancel()
        if value { changedAt = now(); refresh() }
        else { previewCapture?.cancel(); status = .disabled }
    }
    func refresh() {
        guard enabled else { return }
        if previewEnabled { screenRecordingAllowed = CGPreflightScreenCaptureAccess() }
        guard bootSessionID != nil else { status = .captureFailed; return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        guard trusted else { cancel(); status = .permission; return }
        guard !sleeping, !busy else { return }
        if pending, snapshot != nil {
            if restoreRequested { restoreNow(automatically: true) } else { status = .waiting }
        }
        else if snapshot == nil { scheduleBaseline() }
        else { status = .saved }
    }
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    func setPreviewEnabled(_ value: Bool) {
        guard enabled, value != previewEnabled else { return }
        defaults.set(value, forKey: Self.previewKey)
        previewEnabled = value
        screenRecordingAllowed = value && CGPreflightScreenCaptureAccess()
        if !value {
            previewCapture?.cancel()
            artifacts?.retainPreviews(for: [])
        }
    }
    func requestPreviewPermission() {
        guard enabled, previewEnabled else { return }
        screenRecordingAllowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !screenRecordingAllowed,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    func preview(previous: Bool) -> Data? {
        guard enabled, previewEnabled, let layout = previous ? lastGood : snapshot,
              let stored = WindowLayoutPreview.decode(artifacts?.preview(at: layout.date)),
              stored.date == layout.date, stored.images.count == layout.displays.count else { return nil }
        // ScreenCaptureKit images are saved in display ID order.
        let frames = layout.displays.sorted { $0.id < $1.id }.map(\.frame)
        return try? JSONEncoder().encode(WindowLayoutPreview(date: stored.date, images: stored.images, displayFrames: frames))
    }
    func diagnostics() -> Data? { enabled ? artifacts?.diagnostics() : nil }
    private var previewDates: [Date] { [snapshot?.date, lastGood?.date].compactMap { $0 } }
    func willSleep() {
        guard enabled, !sleeping else { return }
        cancel(); sleeping = true
        permission = backend.checkPermission()
        trusted = permission.canAccess
        if trusted { save() }
        else { artifacts?.record(WindowLayoutLogEvent("automaticSave", "accessibilityDenied", layout: snapshot)) }
        if snapshot != nil { setPending(true); setRestoreRequested(true) }
    }
    func didWake() {
        sleeping = false
        guard enabled else { return }
        changedAt = now()
        if snapshot != nil { setPending(true); setRestoreRequested(true) }
        refresh()
        if !trusted, let snapshot {
            artifacts?.record(WindowLayoutLogEvent("automaticRestore", "accessibilityDenied", layout: snapshot))
        }
    }
    func displaysChanged() {
        guard enabled else { return }
        let displays = backend.displays()
        if let observedDisplays, LayoutDisplay.sameTopology(observedDisplays, displays) {
            if pending && restoreRequested && !sleeping && !busy { refresh() }
            return
        }
        observedDisplays = displays
        changedAt = now()
        // A disconnect can precede willSleep. Keep the restore target until the saved display set returns.
        if snapshot != nil {
            setPending(true); status = .waiting
            if restoreRequested && !sleeping && !busy { refresh() }
        } else if !sleeping {
            scheduleBaseline()
        }
    }
    func restoreNow(previous: Bool = false, automatically: Bool = false) {
        guard bootSessionID != nil, enabled, !sleeping, !busy, let saved = (previous ? lastGood : snapshot) else { return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        let action = previous ? "restoreBackup" : (automatically ? "automaticRestore" : "manualRestore")
        guard trusted else {
            status = .permission
            artifacts?.record(WindowLayoutLogEvent(action, "accessibilityDenied", layout: saved))
            return
        }
        cancel(); setPending(true); setRestoreRequested(true); busy = true; status = .waiting; restoreReport = nil
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.task = nil } }
            var previousDisplays: [LayoutDisplay] = [], stable = 0
            for _ in 0..<self.attempts {
                do { try await Task.sleep(for: self.step) } catch { return }
                guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                guard self.backend.isTrusted else {
                    self.trusted = false; self.status = .permission
                    self.artifacts?.record(WindowLayoutLogEvent(action, "accessibilityDenied", layout: saved))
                    return
                }
                let displays = self.backend.displays()
                stable = displays == previousDisplays ? stable + 1 : 0; previousDisplays = displays
                guard stable >= 2, LayoutDisplay.matches(saved.displays, displays) else { continue }
                self.status = .restoring
                self.previewCapture?.cancel()
                var result = self.backend.restore(saved.windows, displays: displays, identityScope: saved.windows)
                // Only retry unsuccessful writes. Never move successful windows again during a retry.
                if !result.failed.isEmpty {
                    do { try await Task.sleep(for: self.step) } catch { return }
                    guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                    guard self.backend.isTrusted, self.backend.displays() == displays else {
                        var report = result.report
                        let interruption: WindowRestoreFailure = self.backend.isTrusted ? .displayChanged : .permissionDenied
                        report.interrupted = interruption
                        self.restoreReport = report; self.status = .incomplete
                        self.artifacts?.record(WindowLayoutLogEvent(action, interruption.rawValue,
                            layout: saved, displays: self.backend.displays(), report: report))
                        return
                    }
                    let retry = self.backend.restore(result.failed, displays: displays, identityScope: saved.windows)
                    result.restored += retry.restored; result.skipped += retry.skipped; result.failed = retry.failed
                    result.issues = retry.issues
                }
                self.restoreReport = result.report
                guard self.backend.displays() == displays else {
                    self.restoreReport?.interrupted = .displayChanged; self.status = .incomplete
                    self.artifacts?.record(WindowLayoutLogEvent(action, "displayChanged", layout: saved,
                        displays: self.backend.displays(), report: self.restoreReport))
                    return
                }
                // Closed or newly minimized/full-screen windows are deliberately skipped.
                // Ambiguous identities and failed writes remain eligible for a restore retry.
                if result.failed.isEmpty && result.restored + result.skipped > 0 {
                    if previous, self.current != saved {
                        let old = self.current
                        self.current = saved; self.lastGood = old ?? self.lastGood
                        if let data = try? JSONEncoder().encode(saved) { self.defaults.set(data, forKey: Self.currentKey) }
                        if let old, let data = try? JSONEncoder().encode(old) { self.defaults.set(data, forKey: Self.backupKey) }
                    }
                    self.setPending(false); self.setRestoreRequested(false); self.status = .restored(result.restored, result.skipped)
                    self.observedDisplays = displays
                    self.artifacts?.record(WindowLayoutLogEvent(action, "restored", layout: saved, displays: displays, report: result.report))
                } else {
                    self.setPending(true)
                    self.status = .incomplete
                    self.artifacts?.record(WindowLayoutLogEvent(action, "incomplete", layout: saved, displays: displays, report: result.report))
                }
                return
            }
            self.setPending(true); self.status = .waiting
            self.artifacts?.record(WindowLayoutLogEvent(action, "displayNotReady", layout: saved, displays: previousDisplays))
        }
    }
    private func scheduleBaseline() {
        cancel(); busy = true; status = .ready
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.task = nil } }
            do { try await Task.sleep(for: self.step * 2) } catch { return }
            guard self.enabled, !self.sleeping, self.generation == token, !Task.isCancelled,
                  !self.pending, self.snapshot == nil else { return }
            self.save()
        }
    }
    func useCurrentLayout() {
        guard enabled, !sleeping else { return }
        cancel()
        restoreReport = nil
        guard bootSessionID != nil else {
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent("manualSave", "bootSessionUnavailable"))
            return
        }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        guard trusted else {
            status = .permission
            artifacts?.record(WindowLayoutLogEvent("manualSave", "accessibilityDenied", layout: snapshot))
            return
        }
        if save(automatically: false) {
            setPending(false)
            setRestoreRequested(false)
        }
    }
    @discardableResult private func save(automatically: Bool = true) -> Bool {
        guard enabled else { return false }
        let action = automatically ? "automaticSave" : "manualSave"
        guard bootSessionID != nil, backend.isTrusted else {
            artifacts?.record(WindowLayoutLogEvent(action, bootSessionID == nil ? "bootSessionUnavailable" : "accessibilityDenied"))
            return false
        }
        if automatically && now() - changedAt < 2 {
            artifacts?.record(WindowLayoutLogEvent(action, "displaySettling", layout: snapshot))
            return false
        }
        let screens = backend.displays()
        guard !screens.isEmpty,
              !automatically || snapshot.map({ LayoutDisplay.matches($0.displays, screens) }) != false else {
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent(action, "displayMismatch", layout: snapshot, displays: screens))
            return false
        }
        let capture = startPreview(displays: screens)
        guard var candidate = backend.capture(timeBudget: automatically ? 2 : 4), candidate.isValid else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent(action, "noValidCapture", layout: snapshot, displays: screens))
            return false
        }
        let finalDisplays = backend.displays()
        guard LayoutDisplay.sameTopology(screens, candidate.displays), LayoutDisplay.sameTopology(screens, finalDisplays) else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent(action, "displayChanged", layout: candidate, displays: finalDisplays))
            return false
        }
        candidate.savedDuringPendingRestore = automatically && pending ? true : nil
        guard let encoded = try? JSONEncoder().encode(candidate), encoded.count <= 1_048_576 else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent(action, "snapshotTooLarge", layout: candidate))
            return false
        }
        // Keep a known baseline if several sleeps capture incomplete or still-unrestored layouts.
        if let current,
           lastGood == nil || (current.savedDuringPendingRestore != true && current.savedWithOmissions != true),
           let backup = try? JSONEncoder().encode(current) {
            lastGood = current; defaults.set(backup, forKey: Self.backupKey)
        }
        defaults.set(encoded, forKey: Self.currentKey)
        current = candidate
        observedDisplays = candidate.displays; restoreReport = nil; status = .saved
        artifacts?.retainPreviews(for: previewDates)
        artifacts?.record(WindowLayoutLogEvent(action, candidate.savedWithOmissions == true ? "savedWithOmissions" : "saved", layout: candidate))
        if let capture { storePreview(capture, for: candidate) }
        return true
    }
    private func startPreview(displays: [LayoutDisplay]) -> Task<[Data], Never>? {
        guard previewEnabled, artifacts != nil else { return nil }
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        guard screenRecordingAllowed else { return nil }
        previewCapture?.cancel()
        let capture = WindowPreviewCapture.start(displays: displays)
        previewCapture = capture
        return capture
    }
    private func storePreview(_ capture: Task<[Data], Never>, for layout: WindowLayoutSnapshot) {
        Task { [weak self] in
            let images = await capture.value
            guard let self, enabled, previewEnabled, !capture.isCancelled, previewDates.contains(layout.date) else { return }
            let stored = images.count == layout.displays.count && artifacts?.store(WindowLayoutPreview(date: layout.date, images: images)) == true
            artifacts?.record(WindowLayoutLogEvent("preview", stored ? "saved" : "unavailable", layout: layout))
            if stored { previewRevision += 1 }
        }
    }
    private func setRestoreRequested(_ value: Bool) { restoreRequested = value; defaults.set(value, forKey: Self.restoreKey) }
    private func setPending(_ value: Bool) { pending = value; defaults.set(value, forKey: Self.pendingKey) }
    private func cancel() { generation += 1; task?.cancel(); task = nil; busy = false }
    func stop() {
        cancel()
        previewCapture?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
    private func installObservers() {
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (WindowLayoutService) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
            observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.willSleepNotification) { $0.willSleep() }
        add(workspace, NSWorkspace.didWakeNotification) { $0.didWake() }
        add(workspace, NSWorkspace.screensDidWakeNotification) { if $0.pending && $0.restoreRequested { $0.refresh() } }
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { if $0.pending && $0.restoreRequested { $0.refresh() } }
        add(.default, NSApplication.didBecomeActiveNotification) { $0.refresh() }
        add(.default, NSApplication.didChangeScreenParametersNotification) { $0.displaysChanged() }
    }
    func report() -> WindowHelperState {
        var report = WindowHelperState(enabled: enabled, busy: busy, phase: status, permission: permission,
                          savedAt: snapshot?.date, backupAt: lastGood?.date, pending: pending, processID: getpid(),
                          restoreReport: restoreReport, savedWithOmissions: snapshot?.savedWithOmissions)
        report.previewEnabled = previewEnabled
        report.screenRecordingAllowed = previewEnabled ? screenRecordingAllowed : nil
        if previewEnabled {
            if artifacts?.hasPreview(at: report.savedAt) == true { report.previewAt = report.savedAt }
            if artifacts?.hasPreview(at: report.backupAt) == true { report.backupPreviewAt = report.backupAt }
        }
        return report
    }
}
