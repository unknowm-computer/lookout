import AppKit
import Combine
import FanControlProtocol
import LookoutCore
import ServiceManagement
import WindowHelperProtocol

/// The UI owns preferences; the user-session helper owns AX objects and sleep/wake handling.
@MainActor final class WindowLayoutClient: ObservableObject {
    static let enabledKey = "windowLayout.enabled.v1"
    @Published private(set) var enabled: Bool
    @Published private(set) var state: WindowHelperState?
    @Published private(set) var connecting = false
    @Published private(set) var connectionError: String?
    private let defaults: UserDefaults
    let maintenance: FanHelperMaintenance
    private var subscriptions: Set<AnyCancellable> = []
    private var connection: NSXPCConnection?
    private var events: WindowClientEvents?
    private var generation = 0
    private var requestsPermissionAfterSetup = false
    private let requestOverride: (@MainActor (String?, Bool, Data?) async throws -> Data?)?
    private let connectionFactory: (@MainActor () throws -> (NSXPCConnection, String))?
    init(defaults: UserDefaults = .standard, revision: String? = nil,
         registrationService: (any FanHelperRegistering)? = nil,
         settle: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         connectionFactory: (@MainActor () throws -> (NSXPCConnection, String))? = nil,
         requestOverride: (@MainActor (String?, Bool, Data?) async throws -> Data?)? = nil) {
        self.defaults = defaults; self.connectionFactory = connectionFactory; self.requestOverride = requestOverride
        enabled = defaults.bool(forKey: Self.enabledKey)
        maintenance = FanHelperMaintenance(defaults: defaults,
            revision: revision ?? (try? HelperRevision.current(.window)), kind: .window,
            service: registrationService, settle: settle)
        maintenance.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        maintenance.$updating.dropFirst().sink { [weak self] updating in
            guard !updating else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }.store(in: &subscriptions)
        refresh()
    }
    var registration: SMAppService.Status { maintenance.status }
    var needsRefresh: Bool { maintenance.needsRefresh }
    var connected: Bool { state != nil }
    var trusted: Bool { connected && state?.permission.canAccess == true }
    var busy: Bool { connecting || maintenance.updating || state?.busy == true }
    var savedAt: Date? { if let state { return state.savedAt }; return legacySnapshot("windowLayout.current.v1")?.date ?? legacySnapshot("windowLayout.lastGood.v1")?.date }
    var backupAt: Date? { if let state { return state.backupAt }; return legacySnapshot("windowLayout.lastGood.v1")?.date }
    var canRestore: Bool { enabled && trusted && savedAt != nil && !busy }
    var statusMessage: String { state?.phase.message ?? L10n.text("창 배치 도우미 연결을 확인해주세요.") }
    private func legacySnapshot(_ key: String) -> WindowLayoutSnapshot? { WindowLayoutSnapshot.decode(defaults.data(forKey: key)) }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if value { refresh() } else { stop() }
    }
    func refresh() {
        maintenance.refresh()
        guard enabled, !maintenance.updating else { return }
        guard registration == .enabled && !needsRefresh else { stop(); return }
        guard !connecting else { return }
        send(action: connected ? "refresh" : nil)
    }
    /// Manual only. Restarts the service connection; no Accessibility approval is synthesized.
    func install() {
        guard !busy else { return }
        maintenance.refresh()
        guard registration != .requiresApproval else { openSystemSettings(); return }
        if registration == .enabled && !needsRefresh && connectionError == nil && maintenance.error == nil {
            if connected && !trusted { openAccessibilitySettings() }
            else { refresh() }
            return
        }
        let repairConnection = connectionError != nil || maintenance.error != nil
        stop(); connectionError = nil
        requestsPermissionAfterSetup = true
        maintenance.activate(force: repairConnection)
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    func openAccessibilitySettings() { send(action: "permission") }
    func restoreNow(previous: Bool = false) { guard canRestore else { return }; send(action: previous ? "previous" : "restore") }
    func useCurrentLayout() { guard enabled && trusted && !busy else { return }; send(action: "baseline") }
    func stop() {
        generation += 1
        requestsPermissionAfterSetup = false
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil
        connection?.invalidate(); connection = nil; events = nil; state = nil; connecting = false
    }
    private func send(action: String?) {
        guard enabled && registration == .enabled && !needsRefresh && !maintenance.updating && !connecting else { return }
        connecting = true; connectionError = nil
        let token = generation
        Task {
            defer { if generation == token { connecting = false } }
            do {
                let data = try await request(action: action, token: token)
                guard generation == token else { return }
                guard let value = WindowHelperState.decode(data) else { throw WindowConnectionError.invalidReply }
                state = value
                if requestsPermissionAfterSetup {
                    requestsPermissionAfterSetup = false
                    if !value.permission.canAccess {
                        let permission = try await request(action: "permission", token: token)
                        guard generation == token else { return }
                        guard let checked = WindowHelperState.decode(permission) else { throw WindowConnectionError.invalidReply }
                        state = checked
                    }
                }
            } catch {
                guard generation == token else { return }
                stop(); connectionError = L10n.text("창 배치 도우미 연결을 확인하지 못했습니다. 다시 설정해주세요.")
            }
        }
    }
    private func request(action: String?, token: Int) async throws -> Data? {
        if let requestOverride { return try await requestOverride(action, enabled, action == nil ? legacyTransfer() : nil) }
        let proxy = try channel(token: token)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WindowReplyGate(continuation)
            if let action { proxy.perform(action) { gate.complete(.success($0)) } }
            else { proxy.configure(enabled, legacy: legacyTransfer()) { gate.complete(.success($0)) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { gate.complete(.failure(WindowConnectionError.timeout)) }
        }
    }
    private func legacyTransfer() -> Data? {
        let transfer = WindowLayoutTransfer(current: legacySnapshot("windowLayout.current.v1").flatMap { try? JSONEncoder().encode($0) },
            backup: legacySnapshot("windowLayout.lastGood.v1").flatMap { try? JSONEncoder().encode($0) }, pending: defaults.bool(forKey: "windowLayout.pending.v1"),
            restoreRequested: defaults.bool(forKey: "windowLayout.restoreRequested.v1"))
        guard let data = try? JSONEncoder().encode(transfer), data.count <= WindowHelperEndpoint.maximumTransferBytes else { return nil }
        return data
    }
    private func channel(token: Int) throws -> WindowHelperProtocol {
        if connection == nil {
            let channel: NSXPCConnection, requirement: String
            if let connectionFactory { (channel, requirement) = try connectionFactory() }
            else {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/" + WindowHelperEndpoint.bundleName)
                requirement = try FanPeerIdentity.requirement(for: helper)
                channel = NSXPCConnection(machServiceName: WindowHelperEndpoint.name)
            }
            channel.setCodeSigningRequirement(requirement)
            channel.remoteObjectInterface = NSXPCInterface(with: WindowHelperProtocol.self)
            channel.exportedInterface = NSXPCInterface(with: WindowHelperEvents.self)
            let receiver = WindowClientEvents { [weak self] data in
                guard let self, self.generation == token, let value = WindowHelperState.decode(data) else { return }
                self.state = value
            }
            events = receiver; channel.exportedObject = receiver
            let failure: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.stop(); self.connectionError = L10n.text("창 배치 도우미 연결이 끊겼습니다. 다시 설정해주세요.")
                }
            }
            channel.interruptionHandler = failure; channel.invalidationHandler = failure
            connection = channel; channel.resume()
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
                self.connectionError = L10n.text("창 배치 도우미 연결을 확인하지 못했습니다. 다시 설정해주세요.")
            }
        }) as? WindowHelperProtocol else {
            throw WindowConnectionError.invalidReply
        }
        return proxy
    }
}
private enum WindowConnectionError: Error { case timeout, invalidReply }
private final class WindowReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    init(_ continuation: CheckedContinuation<Data?, Error>) { self.continuation = continuation }
    func complete(_ result: Result<Data?, Error>) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: result)
    }
}
private final class WindowClientEvents: NSObject, WindowHelperEvents, @unchecked Sendable {
    let update: @MainActor @Sendable (Data) -> Void
    init(update: @escaping @MainActor @Sendable (Data) -> Void) { self.update = update }
    func stateChanged(_ data: Data) { Task { @MainActor [update] in update(data) } }
}
