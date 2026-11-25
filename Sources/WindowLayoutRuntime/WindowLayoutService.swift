import AppKit
import Combine
import WindowLayoutModel
import WindowHelperProtocol

/// Keeps window layout capture separate from metric sampling.
@MainActor final class WindowLayoutService: ObservableObject {
    typealias Status = WindowLayoutPhase
    private enum PauseTrigger {
        case systemSleep, screenSleep, screenLock
    }
    private enum ResumeTrigger: String {
        case systemWake, screenWake, screenUnlock
    }
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
    private(set) var pending = false
    var snapshot: WindowLayoutSnapshot? { current ?? lastGood }
    var canRestore: Bool { enabled && trusted && snapshot != nil && !busy }
    private let defaults: UserDefaults
    private let bootSessionID: String?
    private let backend: any WindowLayoutBackend
    private let artifacts: WindowLayoutArtifacts?
    private let now: () -> TimeInterval
    private let step: Duration
    private let attempts: Int
    private var recentCaptureInterval: Duration
    private var changedAt: TimeInterval
    private var task: Task<Void, Never>?
    private var recentCaptureTask: Task<Void, Never>?
    private var recent: WindowLayoutSnapshot?
    @Published private var lastRecentCaptureAt: Date?
    private var manualLayout: WindowLayoutSnapshot? {
        [current, lastGood].compactMap { $0 }.filter { $0.manuallySaved == true }.max { $0.date < $1.date }
    }
    private var wakeLayout: WindowLayoutSnapshot? { recent ?? manualLayout }
    private var recentFrozen = false
    private var generation = 0
    private var sleeping = false
    private var screensSleeping = false
    private var screenLocked = false
    private var pendingResume: ResumeTrigger?
    private var desktopAvailable: Bool { !sleeping && !screensSleeping && !screenLocked }
    private var previewCapture: Task<[Data], Never>?
    private var observedDisplays: [LayoutDisplay]?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let enabledKey = "windowLayout.enabled.v1"
    static let currentKey = "windowLayout.current.v1"
    static let backupKey = "windowLayout.lastGood.v1"
    static let pendingKey = "windowLayout.pending.v1"
    static let restoreKey = "windowLayout.restoreRequested.v1"
    static let backupProtectionKey = "windowLayout.protectBackup.v1"
    static let bootSessionKey = "windowLayout.bootSession.v1"
    static let previewKey = "windowLayout.preview.v1"

    init(defaults: UserDefaults = .standard, backend: (any WindowLayoutBackend)? = nil,
         observe: Bool = true, startEnabled: Bool = true, step: Duration = .seconds(1), attempts: Int = 30,
         bootSessionID: String? = WindowBootSession.currentID(),
         artifacts: WindowLayoutArtifacts? = nil,
         recentCaptureInterval: Duration = WindowLayoutCaptureInterval.defaultValue.duration,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.backend = backend ?? AccessibilityWindowLayoutBackend()
        self.bootSessionID = bootSessionID
        self.artifacts = artifacts
        previewEnabled = defaults.bool(forKey: Self.previewKey)
        self.now = now; self.step = step; self.attempts = attempts; changedAt = now()
        self.recentCaptureInterval = recentCaptureInterval
        // Old/unscoped snapshots must never be adopted as belonging to this boot.
        // Checking at startup also covers shutdowns where no final notification was delivered.
        if bootSessionID == nil || defaults.string(forKey: Self.bootSessionKey) != bootSessionID {
            for key in [Self.currentKey, Self.backupKey, Self.backupProtectionKey, Self.pendingKey, Self.restoreKey] {
                defaults.removeObject(forKey: key)
            }
            defaults.set(bootSessionID, forKey: Self.bootSessionKey)
        }
        enabled = startEnabled && defaults.bool(forKey: Self.enabledKey)
        func loadLayout(for key: String) -> WindowLayoutSnapshot? {
            guard var layout = WindowLayoutSnapshot.decode(defaults.data(forKey: key)) else { return nil }
            if layout.manuallySaved == nil, artifacts?.confirmsManualSave(layout) == true {
                layout.manuallySaved = true
                if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: key) }
            }
            return layout
        }
        current = loadLayout(for: Self.currentKey)
        lastGood = loadLayout(for: Self.backupKey)
        defaults.removeObject(forKey: Self.backupProtectionKey)
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.restoreKey)
        observedDisplays = snapshot?.displays
        artifacts?.retainPreviews(for: previewEnabled ? previewDates : [])
        if observe { installObservers() }
        if enabled { refresh(); startRecentCapture() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        cancel()
        if value { changedAt = now(); refresh(); startRecentCapture() }
        else {
            pendingResume = nil
            stopRecentCapture()
            previewCapture?.cancel()
            status = .disabled
        }
    }
    func setCaptureInterval(_ value: WindowLayoutCaptureInterval) {
        guard recentCaptureInterval != value.duration else { return }
        recentCaptureInterval = value.duration
        if enabled { startRecentCapture() }
    }
    func refresh() {
        guard enabled, desktopAvailable, !busy else { return }
        if previewEnabled { screenRecordingAllowed = CGPreflightScreenCaptureAccess() }
        guard bootSessionID != nil else { status = .captureFailed; return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        guard trusted else { status = .permission; return }
        if status == .disabled || status == .permission {
            status = snapshot == nil ? .ready : .saved
        }
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
        pauseDesktop(.systemSleep)
    }
    func didWake() {
        guard sleeping else { return }
        sleeping = false
        resumeDesktop(after: .systemWake)
    }
    func screensDidSleep() {
        pauseDesktop(.screenSleep)
    }
    func screensDidWake() {
        guard screensSleeping else { return }
        screensSleeping = false
        resumeDesktop(after: .screenWake)
    }
    func screenDidLock() {
        pauseDesktop(.screenLock)
    }
    func screenDidUnlock() {
        guard screenLocked else { return }
        screenLocked = false
        resumeDesktop(after: .screenUnlock)
    }
    private func pauseDesktop(_ trigger: PauseTrigger) {
        // Lock, display sleep and system sleep may describe a single departure.
        let wasAvailable = desktopAvailable
        switch trigger {
        case .systemSleep: sleeping = true
        case .screenSleep: screensSleeping = true
        case .screenLock: screenLocked = true
        }
        guard enabled, wasAvailable else { return }
        cancel()
        previewCapture?.cancel()
        pending = wakeLayout != nil
    }
    private func resumeDesktop(after event: ResumeTrigger) {
        guard enabled else { return }
        // A system wake may be followed by the display waking and the user unlocking.
        // Consume a single request when all of those barriers have cleared.
        if pendingResume != .systemWake { pendingResume = event }
        if event != .screenUnlock, backend.isScreenLocked { screenLocked = true }
        if event != .screenWake { screensSleeping = backend.areScreensAsleep }
        guard desktopAvailable, let trigger = pendingResume else { return }
        pendingResume = nil
        pending = false
        changedAt = now()
        if let saved = wakeLayout { restore(saved, previous: false, trigger: trigger) }
        else { refresh() }
    }
    func displaysChanged() {
        guard enabled else { return }
        let displays = backend.displays()
        freezeRecentIfDisplaysChanged(displays)
        if let observedDisplays, LayoutDisplay.sameTopology(observedDisplays, displays) { return }
        observedDisplays = displays
        changedAt = now()
    }
    func restoreNow(previous: Bool = false) {
        guard let saved = previous ? lastGood : snapshot else { return }
        restore(saved, previous: previous, trigger: nil)
    }
    private func restore(_ saved: WindowLayoutSnapshot, previous: Bool, trigger: ResumeTrigger?) {
        guard bootSessionID != nil, enabled, desktopAvailable, !busy else { return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        let action = previous ? "restoreBackup" : (trigger != nil ? "automaticRestore" : "manualRestore")
        guard trusted else {
            status = .permission
            artifacts?.record(WindowLayoutLogEvent(action, "accessibilityDenied", layout: saved, trigger: trigger?.rawValue))
            return
        }
        cancel(); pending = true; busy = true; status = .waiting; restoreReport = nil
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.pending = false
                    self.busy = false
                    self.task = nil
                }
            }
            var previousDisplays: [LayoutDisplay] = [], stable = 0
            for _ in 0..<self.attempts {
                do { try await Task.sleep(for: self.step) } catch { return }
                guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                guard self.backend.isTrusted else {
                    self.trusted = false; self.status = .permission
                    self.artifacts?.record(WindowLayoutLogEvent(action, "accessibilityDenied", layout: saved, trigger: trigger?.rawValue))
                    return
                }
                let displays = self.backend.displays()
                stable = displays == previousDisplays ? stable + 1 : 0; previousDisplays = displays
                guard stable >= 2, LayoutDisplay.matches(saved.displays, displays) else { continue }
                self.status = .restoring
                self.previewCapture?.cancel()
                var result = self.backend.restore(saved.windows, displays: displays, identityScope: saved.windows)
                // Retry only the windows that failed, including identification and write failures.
                if !result.failed.isEmpty {
                    do { try await Task.sleep(for: self.step) } catch { return }
                    guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                    guard self.backend.isTrusted, self.backend.displays() == displays else {
                        var report = result.report
                        let interruption: WindowRestoreFailure = self.backend.isTrusted ? .displayChanged : .permissionDenied
                        report.interrupted = interruption
                        self.restoreReport = report; self.status = .incomplete
                        self.artifacts?.record(WindowLayoutLogEvent(action, interruption.rawValue,
                            layout: saved, displays: self.backend.displays(), report: report, trigger: trigger?.rawValue))
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
                        displays: self.backend.displays(), report: self.restoreReport, trigger: trigger?.rawValue))
                    return
                }
                // Closed or newly minimized/full-screen windows are deliberately skipped.
                if result.failed.isEmpty && result.restored + result.skipped > 0 {
                    if previous, self.current != saved {
                        let old = self.current
                        self.current = saved; self.lastGood = old ?? self.lastGood
                        if let data = try? JSONEncoder().encode(saved) { self.defaults.set(data, forKey: Self.currentKey) }
                        if let old, let data = try? JSONEncoder().encode(old) { self.defaults.set(data, forKey: Self.backupKey) }
                    }
                    if trigger == nil { self.clearRecentLayout() }
                    self.recentFrozen = false
                    self.status = .restored(result.restored, result.skipped)
                    self.observedDisplays = displays
                    self.retainWindowReferences()
                    self.artifacts?.record(WindowLayoutLogEvent(action, "restored", layout: saved, displays: displays,
                                                              report: result.report, trigger: trigger?.rawValue))
                } else {
                    self.status = .incomplete
                    self.artifacts?.record(WindowLayoutLogEvent(action, "incomplete", layout: saved, displays: displays,
                                                              report: result.report, trigger: trigger?.rawValue))
                }
                return
            }
            self.status = .displayNotReady
            self.artifacts?.record(WindowLayoutLogEvent(action, "displayNotReady", layout: saved, displays: previousDisplays,
                                                      trigger: trigger?.rawValue))
        }
    }
    func useCurrentLayout() {
        guard enabled, desktopAvailable, !backend.isScreenLocked, !backend.areScreensAsleep else { return }
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
        saveManualLayout()
    }

    private func startRecentCapture() {
        recentCaptureTask?.cancel()
        let interval = recentCaptureInterval
        let tolerance = min(.seconds(1), interval / 10)
        recentCaptureTask = Task { [weak self] in
            var delay = min(.seconds(2), interval)
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay, tolerance: tolerance) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.captureRecentLayout()
                delay = interval
            }
        }
    }

    private func stopRecentCapture() {
        recentCaptureTask?.cancel()
        recentCaptureTask = nil
        lastRecentCaptureAt = nil
        clearRecentLayout()
    }

    private func clearRecentLayout() {
        recent = nil
        recentFrozen = false
        retainWindowReferences()
    }

    private func freezeRecentIfDisplaysChanged(_ displays: [LayoutDisplay]) {
        if let recent, !LayoutDisplay.matches(recent.displays, displays) { recentFrozen = true }
    }

    private func captureRecentLayout() async {
        guard enabled, trusted, desktopAvailable, !busy, !recentFrozen, bootSessionID != nil,
              now() - changedAt >= 2, !backend.isScreenLocked, backend.captureDisplaysAwake else { return }
        let screens = backend.displays()
        freezeRecentIfDisplaysChanged(screens)
        guard !screens.isEmpty, !recentFrozen else { return }
        if let reference = wakeLayout, !LayoutDisplay.matches(reference.displays, screens) { return }
        let token = generation
        defer { retainWindowReferences() }
        guard let candidate = backend.capture(timeBudget: 2), candidate.isValid,
              candidate.savedWithOmissions != true, candidate.date >= (recent?.date ?? .distantPast) else { return }
        // AX enumeration is synchronous. Let queued workspace notifications run before accepting the sample.
        await Task.yield()
        guard !Task.isCancelled, generation == token, desktopAvailable, !backend.isScreenLocked,
              backend.captureDisplaysAwake else { return }
        let finalDisplays = backend.displays()
        freezeRecentIfDisplaysChanged(finalDisplays)
        guard !recentFrozen, LayoutDisplay.sameTopology(screens, candidate.displays),
              LayoutDisplay.sameTopology(screens, finalDisplays) else { return }
        recent = candidate
        lastRecentCaptureAt = candidate.date
    }

    private func retainWindowReferences() {
        let ids = [current, lastGood, recent].compactMap { $0 }.flatMap { $0.windows.map(\.id) }
        backend.retainReferences(for: Set(ids))
    }

    private func saveManualLayout() {
        let token = generation
        let screens = backend.displays()
        let capture = startPreview(displays: screens)
        defer { retainWindowReferences() }
        let captured = backend.capture(timeBudget: 4)
        guard generation == token, desktopAvailable, !backend.isScreenLocked, !backend.areScreensAsleep else {
            capture?.cancel()
            return
        }
        guard var candidate = captured, candidate.isValid else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent("manualSave", "noValidCapture", layout: snapshot, displays: screens))
            return
        }
        let finalDisplays = backend.displays()
        guard LayoutDisplay.sameTopology(screens, candidate.displays), LayoutDisplay.sameTopology(screens, finalDisplays) else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent("manualSave", "displayChanged", layout: candidate, displays: finalDisplays))
            return
        }
        candidate.manuallySaved = true
        guard let encoded = try? JSONEncoder().encode(candidate), encoded.count <= 1_048_576 else {
            capture?.cancel()
            status = .captureFailed
            artifacts?.record(WindowLayoutLogEvent("manualSave", "snapshotTooLarge", layout: candidate))
            return
        }
        let outcome = candidate.savedWithOmissions == true ? "savedWithOmissions" : "saved"
        if let current,
           lastGood == nil || (current.savedDuringPendingRestore != true && current.savedWithOmissions != true),
           let backup = try? JSONEncoder().encode(current) {
            lastGood = current; defaults.set(backup, forKey: Self.backupKey)
        }
        defaults.set(encoded, forKey: Self.currentKey)
        current = candidate
        if candidate.savedWithOmissions != true || recent.map({ !LayoutDisplay.matches($0.displays, screens) }) == true {
            clearRecentLayout()
        }
        observedDisplays = candidate.displays; restoreReport = nil; status = .saved
        artifacts?.retainPreviews(for: previewDates)
        artifacts?.record(WindowLayoutLogEvent("manualSave", outcome, layout: candidate))
        if let capture { storePreview(capture, for: candidate) }
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
    private func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pending = false
        busy = false
    }
    func stop() {
        pendingResume = nil
        cancel()
        stopRecentCapture()
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
        screensSleeping = backend.areScreensAsleep
        screenLocked = backend.isScreenLocked
        add(workspace, NSWorkspace.willSleepNotification) { $0.willSleep() }
        add(workspace, NSWorkspace.didWakeNotification) { $0.didWake() }
        add(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensDidSleep() }
        add(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensDidWake() }
        let session = DistributedNotificationCenter.default()
        add(session, Notification.Name("com.apple.screenIsLocked")) { $0.screenDidLock() }
        add(session, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenDidUnlock() }
        add(.default, NSApplication.didBecomeActiveNotification) { $0.refresh() }
        add(.default, NSApplication.didChangeScreenParametersNotification) { $0.displaysChanged() }
    }
    func report() -> WindowHelperState {
        var report = WindowHelperState(enabled: enabled, busy: busy, phase: status, permission: permission,
                          savedAt: snapshot?.date, backupAt: lastGood?.date, pending: pending, processID: getpid(),
                          restoreReport: restoreReport, savedWithOmissions: snapshot?.savedWithOmissions)
        report.lastRecentCaptureAt = lastRecentCaptureAt
        report.previewEnabled = previewEnabled
        report.screenRecordingAllowed = previewEnabled ? screenRecordingAllowed : nil
        if previewEnabled {
            if artifacts?.hasPreview(at: report.savedAt) == true { report.previewAt = report.savedAt }
            if artifacts?.hasPreview(at: report.backupAt) == true { report.backupPreviewAt = report.backupAt }
        }
        return report
    }
}
