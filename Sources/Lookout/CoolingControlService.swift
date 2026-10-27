import Combine
import FanControlProtocol
import Foundation
import LookoutCore
import ServiceManagement

/// Read-only monitoring needs no helper. The privileged connection exists only during custom cooling.
@MainActor final class CoolingControlService: ObservableObject {
    @Published private(set) var appliedMode = CoolingMode.system
    @Published private var changingMode = false
    @Published private(set) var message: String?
    var busy: Bool { changingMode || maintenance.updating }
    var registration: SMAppService.Status { maintenance.status }
    var needsRefresh: Bool { maintenance.needsRefresh }
    var updatingHelper: Bool { maintenance.updating }
    var helperError: String? { maintenance.error }
    var helperPreviouslyEnabled: Bool { maintenance.previouslyEnabled }
    private let maintenance: FanHelperMaintenance
    private var maintenanceSubscription: AnyCancellable?
    private let connectionFactory: (@MainActor () throws -> (NSXPCConnection, String))?
    private let defaults: UserDefaults
    private var connection: NSXPCConnection?
    private var attemptedRestore = false
    private var pulsing = false
    private var generation = 0
    private var pendingMode: CoolingMode?
    private var retryAfterMaintenance: CoolingMode?
    init(defaults: UserDefaults = .standard, helperRevision: String? = nil,
         registrationService: (any FanHelperRegistering)? = nil,
         helperSettle: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         connectionFactory: (@MainActor () throws -> (NSXPCConnection, String))? = nil) {
        self.defaults = defaults
        self.connectionFactory = connectionFactory
        // The enclosing app signature seals the helper too. Ad-hoc app rebuilds change
        // launchd's parent identity even when the helper's executable is unchanged.
        maintenance = FanHelperMaintenance(defaults: defaults,
            revision: helperRevision ?? (try? FanPeerIdentity.requirement(for: Bundle.main.bundleURL)),
            service: registrationService, settle: helperSettle)
        maintenanceSubscription = maintenance.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        maintenance.onReady = { [weak self] in
            guard let self else { return }
            self.attemptedRestore = false; self.message = nil
            if let mode = self.retryAfterMaintenance {
                self.retryAfterMaintenance = nil
                self.select(mode)
            }
        }
    }
    func refresh() { maintenance.refresh() }
    func prepareHelperAfterUpdate() {
        guard appliedMode == .system else {
            refresh()
            if registration != .enabled { stop() }
            return
        }
        maintenance.checkForUpdate()
    }
    func install() {
        guard !busy, appliedMode == .system else { return }
        message = nil; maintenance.activate()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    func select(_ mode: CoolingMode) {
        guard !changingMode else { return }
        if updatingHelper { retryAfterMaintenance = mode; return }
        retryAfterMaintenance = nil
        refresh()
        if mode != .system, needsRefresh {
            retryAfterMaintenance = mode
            maintenance.checkForUpdate()
            if updatingHelper { return }
            retryAfterMaintenance = nil
        }
        guard mode == .system || registration == .enabled && !needsRefresh else {
            if registration == .requiresApproval, helperPreviouslyEnabled {
                retryAfterMaintenance = mode; message = nil
            } else { message = L10n.text("팬 제어를 활성화하고 시스템 설정에서 허용해주세요.") }
            return
        }
        // A deliberate selection supersedes startup restoration on the next metric pulse.
        attemptedRestore = true
        changingMode = true; message = nil; pendingMode = mode
        generation += 1
        let token = generation
        Task {
            defer { if generation == token { changingMode = false; pendingMode = nil } }
            do {
                if mode == .system, connection == nil, registration != .enabled { appliedMode = .system }
                else {
                    let channel = try channel()
                    let reply: String? = try await request { callback in
                        if mode == .system { channel.restore(reply: callback) }
                        else { channel.setMode(mode.rawValue, reply: callback) }
                    }
                    guard generation == token else { return }
                    if let reply { throw ControlError.helper(reply) }
                    appliedMode = mode
                }
                defaults.set(mode.rawValue, forKey: "coolingMode.v1")
                if mode == .system { disconnect() }
            } catch {
                guard generation == token else { return }
                if mode != .system { disconnect(); appliedMode = .system }
                message = Self.errorText(error)
            }
        }
    }
    /// Uses the existing metric loop as a lease heartbeat. No separate app timer.
    func pulse(reading: CoolingReading?, enabled: Bool) {
        if !enabled {
            attemptedRestore = true
            if appliedMode != .system || connection != nil { stop() }
            return
        }
        if !attemptedRestore, let reading {
            let saved = defaults.string(forKey: "coolingMode.v1").flatMap(CoolingMode.init(rawValue:)) ?? .system
            if busy || saved != .system && (!reading.canControl || registration != .enabled || needsRefresh) { return }
            attemptedRestore = true
            if saved != .system, reading.canControl {
                if registration == .enabled && !needsRefresh { select(saved) }
            }
        }
        guard appliedMode != .system, !busy, !pulsing else { return }
        guard let reading, reading.canControl else { stop(); message = L10n.text("센서 조회가 중단되어 시스템 자동으로 복귀합니다."); return }
        pulsing = true
        let token = generation
        do {
            let channel = try channel()
            let gate = StateReplyGate { [weak self] data, error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.pulsing = false
                    if error != nil { self.stop(); self.message = L10n.text("팬 제어 연결이 끊겨 시스템 자동으로 복귀합니다."); return }
                    guard let data, let state = try? JSONDecoder().decode(FanControlStatus.self, from: data) else { self.stop(); return }
                    if state.message == nil, state.mode == CoolingMode.system.rawValue {
                        self.appliedMode = .system; self.disconnect()
                    }
                    if let error = state.message {
                        self.message = Self.errorText(ControlError.helper(error))
                        if error != "restoreFailed" { self.appliedMode = .system; self.disconnect() }
                    }
                }
            }
            channel.heartbeat { @Sendable data, error in gate.complete(data, error) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { gate.complete(nil, "timeout") }
        } catch { pulsing = false; stop(); message = Self.errorText(error) }
    }
    func prepareToResume() { attemptedRestore = false }
    func stop() {
        generation += 1; changingMode = false; pendingMode = nil; retryAfterMaintenance = nil
        // Invalidating the authenticated session triggers helper restoration; its lease is a fallback.
        disconnect(); appliedMode = .system; pulsing = false
    }
    private func disconnect() { connection?.invalidate(); connection = nil }
    private func channel() throws -> FanControlProtocol {
        if connection == nil {
            let channel: NSXPCConnection
            let requirement: String
            if let connectionFactory { (channel, requirement) = try connectionFactory() }
            else {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers/LookoutFanHelper")
                channel = NSXPCConnection(machServiceName: FanControlEndpoint.name, options: .privileged)
                requirement = try FanPeerIdentity.requirement(for: helper)
            }
            channel.setCodeSigningRequirement(requirement)
            channel.remoteObjectInterface = NSXPCInterface(with: FanControlProtocol.self)
            let weakChannel = WeakFanConnection(channel)
            channel.interruptionHandler = { @Sendable in weakChannel.invalidate() }
            channel.resume(); connection = channel
        }
        let token = generation
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                let requested = self.pendingMode ?? (self.appliedMode == .system ? nil : self.appliedMode)
                self.stop()
                if self.maintenance.repairOnce() {
                    self.retryAfterMaintenance = requested; self.message = nil
                } else if self.registration == .requiresApproval {
                    self.retryAfterMaintenance = requested; self.message = nil
                } else {
                    self.message = self.helperError != nil ? nil : Self.errorText(error)
                }
            }
        }) as? FanControlProtocol else { throw ControlError.unavailable }
        return proxy
    }
    private func request(_ send: (@escaping @Sendable (String?) -> Void) -> Void) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ErrorReplyGate(continuation)
            send { @Sendable reply in gate.complete(.success(reply)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { gate.complete(.failure(ControlError.timeout)) }
        }
    }
    private enum ControlError: Error { case helper(String), unavailable, timeout }
    private static func errorText(_ error: Error) -> String {
        if case ControlError.helper("externalController") = error {
            return L10n.text("이미 다른 팬 제어가 사용 중입니다. 해당 앱을 시스템 자동으로 바꾼 뒤 다시 선택하세요.")
        }
        if case ControlError.helper("restoreFailed") = error {
            return L10n.text("시스템 자동 복귀를 확인하지 못했습니다. 팬 제어 helper가 복귀를 재시도합니다.")
        }
        return L10n.text("팬 제어를 적용하지 못했습니다. 시스템 자동으로 복귀합니다.")
    }
}

private final class ErrorReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    init(_ continuation: CheckedContinuation<String?, Error>) { self.continuation = continuation }
    func complete(_ result: Result<String?, Error>) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: result)
    }
}
private final class StateReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?, String?) -> Void)?
    init(_ callback: @escaping @Sendable (Data?, String?) -> Void) { self.callback = callback }
    func complete(_ data: Data?, _ error: String?) {
        lock.lock(); let block = callback; callback = nil; lock.unlock(); block?(data, error)
    }
}

/// NSXPCConnection permits invalidate from any queue. Keep only a weak reference in its callback.
private final class WeakFanConnection: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    init(_ connection: NSXPCConnection) { self.connection = connection }
    func invalidate() { connection?.invalidate() }
}
