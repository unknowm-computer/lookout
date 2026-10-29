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
    private(set) var pending: Bool
    private var restoreRequested: Bool
    var snapshot: WindowLayoutSnapshot? { current ?? lastGood }
    var canRestore: Bool { enabled && trusted && snapshot != nil && !busy }
    private let defaults: UserDefaults
    private let backend: any WindowLayoutBackend
    private let now: () -> TimeInterval
    private let step: Duration
    private let attempts: Int
    private var changedAt: TimeInterval
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sleeping = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let enabledKey = "windowLayout.enabled.v1"
    static let currentKey = "windowLayout.current.v1"
    static let backupKey = "windowLayout.lastGood.v1"
    static let pendingKey = "windowLayout.pending.v1"
    static let restoreKey = "windowLayout.restoreRequested.v1"

    init(defaults: UserDefaults = .standard, backend: (any WindowLayoutBackend)? = nil,
         observe: Bool = true, startEnabled: Bool = true, step: Duration = .seconds(1), attempts: Int = 30,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.backend = backend ?? AccessibilityWindowLayoutBackend()
        self.now = now; self.step = step; self.attempts = attempts; changedAt = now()
        enabled = startEnabled && defaults.bool(forKey: Self.enabledKey)
        current = WindowLayoutSnapshot.decode(defaults.data(forKey: Self.currentKey))
        lastGood = WindowLayoutSnapshot.decode(defaults.data(forKey: Self.backupKey))
        pending = defaults.bool(forKey: Self.pendingKey)
        restoreRequested = defaults.bool(forKey: Self.restoreKey)
        if snapshot == nil { pending = false; restoreRequested = false }
        if observe { installObservers() }
        if enabled { refresh() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        cancel()
        if value { changedAt = now(); refresh() }
        else { status = .disabled }
    }
    func refresh() {
        guard enabled else { return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        guard trusted else { cancel(); status = .permission; return }
        guard !sleeping, !busy else { return }
        if pending, snapshot != nil {
            if restoreRequested { restoreNow() } else { status = .waiting }
        }
        else if snapshot == nil { scheduleBaseline() }
        else { status = .saved }
    }
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    func willSleep() {
        guard enabled else { return }
        cancel(); sleeping = true
        permission = backend.checkPermission()
        trusted = permission.canAccess
        if trusted && !pending { save() }
        if snapshot != nil { setPending(true); setRestoreRequested(true) }
    }
    func didWake() {
        sleeping = false
        guard enabled else { return }
        changedAt = now()
        if snapshot != nil { setPending(true); setRestoreRequested(true) }
        refresh()
    }
    func displaysChanged() {
        guard enabled else { return }
        changedAt = now()
        // A disconnect can precede willSleep. Freeze the existing snapshot immediately.
        if snapshot != nil {
            setPending(true); status = .waiting
            if restoreRequested && !sleeping && !busy { refresh() }
        }
    }
    func restoreNow(previous: Bool = false) {
        guard enabled, !sleeping, !busy, let saved = (previous ? lastGood : snapshot) else { return }
        permission = backend.checkPermission()
        trusted = permission.canAccess
        guard trusted else { status = .permission; return }
        cancel(); setPending(true); setRestoreRequested(true); busy = true; status = .waiting
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.task = nil } }
            var previousDisplays: [LayoutDisplay] = [], stable = 0
            for _ in 0..<self.attempts {
                do { try await Task.sleep(for: self.step) } catch { return }
                guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                guard self.backend.isTrusted else { self.trusted = false; self.status = .permission; return }
                let displays = self.backend.displays()
                stable = displays == previousDisplays ? stable + 1 : 0; previousDisplays = displays
                guard stable >= 2, LayoutDisplay.matches(saved.displays, displays) else { continue }
                self.status = .restoring
                var result = self.backend.restore(saved.windows, displays: displays)
                // Only retry unsuccessful writes. Never move successful windows again during a retry.
                if !result.failed.isEmpty {
                    do { try await Task.sleep(for: self.step) } catch { return }
                    guard self.enabled, self.generation == token, !Task.isCancelled else { return }
                    guard self.backend.isTrusted, self.backend.displays() == displays else {
                        self.status = .incomplete; return
                    }
                    let retry = self.backend.restore(result.failed, displays: displays)
                    result.restored += retry.restored; result.skipped += retry.skipped; result.failed = retry.failed
                }
                guard self.backend.displays() == displays else { self.status = .incomplete; return }
                // Closed or newly minimized/full-screen windows are deliberately skipped.
                // Ambiguous identities and failed writes remain protected.
                if result.failed.isEmpty && result.restored + result.skipped > 0 {
                    if previous, self.current != saved {
                        let old = self.current
                        self.current = saved; self.lastGood = old ?? self.lastGood
                        if let data = try? JSONEncoder().encode(saved) { self.defaults.set(data, forKey: Self.currentKey) }
                        if let old, let data = try? JSONEncoder().encode(old) { self.defaults.set(data, forKey: Self.backupKey) }
                    }
                    self.setPending(false); self.setRestoreRequested(false); self.status = .restored(result.restored, result.skipped)
                } else {
                    self.setPending(true)
                    self.status = result.failed.isEmpty ? .restored(result.restored, result.skipped) : .incomplete
                }
                return
            }
            self.setPending(true); self.status = .waiting
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
        guard enabled, !sleeping, !busy, now() - changedAt >= 2, backend.isTrusted else { return }
        let wasPending = pending
        setPending(false)
        save(requireMatchingDisplays: false)
        if status == .captureFailed { setPending(wasPending) }
        else { setRestoreRequested(false) }
    }
    private func save(requireMatchingDisplays: Bool = true) {
        guard enabled, !pending, now() - changedAt >= 2, backend.isTrusted else { return }
        let screens = backend.displays()
        guard (!requireMatchingDisplays || snapshot.map({ LayoutDisplay.matches($0.displays, screens) }) ?? !screens.isEmpty),
              let candidate = backend.capture(), candidate.isValid,
              candidate.displays == screens, backend.displays() == screens,
              let encoded = try? JSONEncoder().encode(candidate), encoded.count <= 1_048_576 else {
            status = .captureFailed; return
        }
        if let current, current.isValid, let backup = try? JSONEncoder().encode(current) {
            lastGood = current; defaults.set(backup, forKey: Self.backupKey)
        }
        current = candidate; defaults.set(encoded, forKey: Self.currentKey); status = .saved
    }
    private func setRestoreRequested(_ value: Bool) { restoreRequested = value; defaults.set(value, forKey: Self.restoreKey) }
    private func setPending(_ value: Bool) { pending = value; defaults.set(value, forKey: Self.pendingKey) }
    private func cancel() { generation += 1; task?.cancel(); task = nil; busy = false }
    func stop() {
        cancel()
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
    func importLegacy(_ transfer: WindowLayoutTransfer?) {
        guard !defaults.bool(forKey: "windowLayout.helperMigrated.v1") else { return }
        defer { defaults.set(true, forKey: "windowLayout.helperMigrated.v1") }
        guard current == nil && lastGood == nil, let transfer else { return }
        if let value = transfer.validCurrent, let data = try? JSONEncoder().encode(value) {
            current = value; defaults.set(data, forKey: Self.currentKey)
        }
        if let value = transfer.validBackup, let data = try? JSONEncoder().encode(value) {
            lastGood = value; defaults.set(data, forKey: Self.backupKey)
        }
        if snapshot != nil {
            setPending(transfer.pending); setRestoreRequested(transfer.restoreRequested)
        }
    }
    func report() -> WindowHelperState {
        WindowHelperState(enabled: enabled, busy: busy, phase: status, permission: permission,
                          savedAt: snapshot?.date, backupAt: lastGood?.date, pending: pending, processID: getpid())
    }
}
