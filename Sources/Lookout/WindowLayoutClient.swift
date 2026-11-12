import AppKit
import Combine
import FanControlProtocol
import LookoutCore
import ServiceManagement
import UniformTypeIdentifiers
import WindowHelperProtocol

/// The UI owns preferences; the user-session helper owns AX objects and sleep/wake handling.
@MainActor final class WindowLayoutClient: ObservableObject {
    static let enabledKey = "windowLayout.enabled.v1"
    @Published private(set) var enabled: Bool
    @Published private(set) var state: WindowHelperState?
    @Published private(set) var connecting = false
    @Published private(set) var connectionError: String?
    @Published private(set) var exportingDiagnostics = false
    private let defaults: UserDefaults
    let maintenance: FanHelperMaintenance
    private var subscriptions: Set<AnyCancellable> = []
    private var connection: NSXPCConnection?
    private var events: WindowClientEvents?
    private var generation = 0
    private var requestsPermissionAfterSetup = false
    private var saveAfterRequest = false
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
    var savedAt: Date? { state?.savedAt }
    var backupAt: Date? { state?.backupAt }
    var savedPreviewAt: Date? {
        guard enabled, state?.previewEnabled == true,
              let savedAt, state?.previewAt == savedAt else { return nil }
        return savedAt
    }
    var canRestore: Bool { enabled && trusted && savedAt != nil && !busy }
    var canSave: Bool { enabled && trusted && !connecting && !maintenance.updating }
    var statusMessage: String { state?.phase.message ?? L10n.text("창 배치 도우미 연결을 확인해주세요.") }
    var saveNotice: String? {
        guard state?.savedWithOmissions == true else { return nil }
        return L10n.text("일부 창을 조회하지 못했습니다. 확인한 창으로 현재 배치를 저장했습니다.")
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if value { install() } else { stop() }
    }
    func refresh() {
        maintenance.refresh()
        guard enabled, !maintenance.updating else { return }
        guard registration == .enabled && !needsRefresh else {
            if registration == .requiresApproval { disconnect() }
            else { stop() }
            return
        }
        guard !connecting else { return }
        send(action: connected ? "refresh" : nil)
    }
    /// Runs after the user enables the feature or asks to repair it.
    func install() {
        guard enabled, !connecting, state?.busy != true else { return }
        requestsPermissionAfterSetup = true
        guard !maintenance.updating else { return }
        maintenance.refresh()
        guard registration != .requiresApproval else { return }
        if registration == .enabled && !needsRefresh && connectionError == nil && maintenance.error == nil {
            refresh()
            return
        }
        let repairConnection = connectionError != nil || maintenance.error != nil
        disconnect(); connectionError = nil
        maintenance.activate(force: repairConnection)
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    func setPreviewEnabled(_ value: Bool) { send(action: value ? "previewOn" : "previewOff") }
    func requestPreviewPermission() { send(action: "previewPermission") }
    func loadPreview(previous: Bool, date: Date) async -> WindowLayoutPreview? {
        guard enabled, connected, state?.previewEnabled == true else { return nil }
        let token = generation
        let data = try? await request(action: previous ? "previousPreview" : "preview", token: token)
        guard generation == token, state?.previewEnabled == true,
              let preview = WindowLayoutPreview.decode(data), preview.date == date else { return nil }
        return preview
    }
    func exportDiagnostics() {
        guard enabled, connected, !exportingDiagnostics else { return }
        exportingDiagnostics = true
        let token = generation
        Task {
            defer { exportingDiagnostics = false }
            let data = try? await request(action: "diagnostics", token: token)
            guard generation == token else { return }
            guard let data, data.count <= WindowHelperEndpoint.maximumTransferBytes,
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                showDiagnosticsError()
                return
            }
            let panel = NSSavePanel()
            panel.title = L10n.text("진단 로그 저장")
            panel.allowedContentTypes = [.json]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            panel.nameFieldStringValue = "Lookout-WindowLayout-\(formatter.string(from: Date())).json"
            NSApp.activate()
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { showDiagnosticsError() }
        }
    }
    private func showDiagnosticsError() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.text("진단 로그를 저장하지 못했습니다.")
        alert.alertStyle = .warning
        alert.runModal()
    }
    func restoreNow(previous: Bool = false) { guard canRestore else { return }; send(action: previous ? "previous" : "restore") }
    func useCurrentLayout() {
        guard enabled, trusted, !maintenance.updating else { return }
        if connecting { saveAfterRequest = true }
        else { send(action: "baseline") }
    }
    func stop() {
        requestsPermissionAfterSetup = false
        disconnect()
    }
    private func disconnect() {
        generation += 1
        saveAfterRequest = false
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil
        connection?.invalidate(); connection = nil; events = nil; state = nil; connecting = false
    }
    private func send(action: String?) {
        guard enabled && registration == .enabled && !needsRefresh && !maintenance.updating && !connecting else { return }
        connecting = true; connectionError = nil
        let token = generation
        Task {
            defer {
                if generation == token {
                    connecting = false
                    if saveAfterRequest {
                        saveAfterRequest = false
                        useCurrentLayout()
                    }
                }
            }
            guard generation == token else { return }
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
        if let requestOverride { return try await requestOverride(action, enabled, nil) }
        let proxy = try channel(token: token)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WindowReplyGate(continuation)
            if let action { proxy.perform(action) { gate.complete(.success($0)) } }
            else { proxy.configure(enabled, legacy: nil) { gate.complete(.success($0)) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { gate.complete(.failure(WindowConnectionError.timeout)) }
        }
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
