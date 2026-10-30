import Foundation
import LookoutCore
import ServiceManagement
import WindowHelperProtocol
@testable import Lookout
import Testing

@MainActor private func windowDefaults() throws -> (String, UserDefaults) {
    let name = "LookoutTests.windowHelper.\(UUID().uuidString)"
    return (name, try #require(UserDefaults(suiteName: name)))
}
@Test @MainActor func windowHelperDoesNotRegisterOrConnectUntilUserEnablesAndSetsItUp() throws {
    let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let registration = FakeFanHelperRegistration(status: .notRegistered)
    var connections = 0
    enum Unexpected: Error { case connection }
    let client = WindowLayoutClient(defaults: defaults, revision: "new", registrationService: registration,
        connectionFactory: { connections += 1; throw Unexpected.connection })
    client.refresh(); client.setEnabled(true); client.refresh(); client.setEnabled(false)
    #expect(registration.registrations == 0 && registration.unregistrations == 0)
    #expect(connections == 0 && !client.connected && !client.trusted && !client.canRestore)
}
@Test @MainActor func windowAndFanRegistrationRevisionRecordsAreIndependent() async throws {
    let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("fan-new", forKey: FanHelperMaintenance.revisionKey)
    defaults.set("window-old", forKey: HelperServiceKind.window.revisionKey)
    let registration = FakeFanHelperRegistration(status: .enabled)
    let window = FanHelperMaintenance(defaults: defaults, revision: "window-new", kind: .window,
        service: registration, settle: { await Task.yield() })
    window.refresh(); #expect(window.needsRefresh)
    window.activate(); window.activate()
    for _ in 0..<100 where window.updating { try await Task.sleep(for: .milliseconds(2)) }
    #expect(registration.registrations == 1 && registration.unregistrations == 1)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "fan-new")
    #expect(defaults.string(forKey: HelperServiceKind.window.revisionKey) == "window-new")
    #expect(!defaults.bool(forKey: FanHelperMaintenance.enabledKey))
    #expect(defaults.bool(forKey: HelperServiceKind.window.enabledKey))
}
@Test @MainActor func staleWindowHelperAndBackgroundApprovalDoNotConnectOrAutomaticallyRepair() throws {
    for status in [SMAppService.Status.enabled, .requiresApproval, .notRegistered] {
        let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: WindowLayoutClient.enabledKey)
        defaults.set("old", forKey: HelperServiceKind.window.revisionKey)
        let registration = FakeFanHelperRegistration(status: status)
        var connections = 0
        enum Unexpected: Error { case connection }
        let client = WindowLayoutClient(defaults: defaults, revision: "new", registrationService: registration,
            connectionFactory: { connections += 1; throw Unexpected.connection })
        client.refresh(); client.refresh()
        #expect(connections == 0 && !client.trusted && client.state == nil)
        #expect(registration.registrations == 0 && registration.unregistrations == 0)
    }
}
@Test @MainActor func windowConnectionFailureDoesNotReregisterOrDeleteLegacySnapshots() async throws {
    let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: WindowLayoutClient.enabledKey)
    defaults.set("new", forKey: HelperServiceKind.window.revisionKey)
    let data = Data("saved sentinel".utf8)
    defaults.set(data, forKey: "windowLayout.current.v1")
    let registration = FakeFanHelperRegistration(status: .enabled)
    enum Unavailable: Error { case connection }
    let client = WindowLayoutClient(defaults: defaults, revision: "new", registrationService: registration,
        connectionFactory: { throw Unavailable.connection })
    for _ in 0..<50 where client.connecting { try await Task.sleep(for: .milliseconds(2)) }
    #expect(client.connectionError != nil && !client.connected && !client.trusted)
    #expect(registration.registrations == 0 && registration.unregistrations == 0)
    #expect(defaults.data(forKey: "windowLayout.current.v1") == data)
    #expect(client.savedAt == nil && client.backupAt == nil && !client.canRestore)
}

@Test @MainActor func windowHelperDoesNotResendUnscopedLegacyDataOnConnection() async throws {
    let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: WindowLayoutClient.enabledKey)
    defaults.set("same", forKey: HelperServiceKind.window.revisionKey)
    defaults.set(Data("legacy snapshot".utf8), forKey: "windowLayout.current.v1")
    defaults.set(true, forKey: "windowLayout.pending.v1")
    defaults.set(true, forKey: "windowLayout.restoreRequested.v1")
    var configured = false
    let client = WindowLayoutClient(defaults: defaults, revision: "same",
        registrationService: FakeFanHelperRegistration(status: .enabled),
        requestOverride: { action, _, legacy in
            #expect(legacy == nil)
            if action == nil { configured = true }
            return try JSONEncoder().encode(WindowHelperState(enabled: true, busy: false, phase: .ready,
                permission: WindowAccessReport(trustedAPI: true, query: .allowed), savedAt: nil,
                backupAt: nil, pending: false, processID: 123))
        })
    defer { client.stop() }
    for _ in 0..<100 where client.busy { try await Task.sleep(for: .milliseconds(2)) }
    #expect(configured && client.connected && client.savedAt == nil && !client.canRestore)
}
@Test func actualAXQueryDistinguishesPermissionFromAnUnresponsiveTarget() {
    #expect(WindowAccessReport(trustedAPI: false, query: .allowed).canAccess)
    #expect(!WindowAccessReport(trustedAPI: true, query: .denied).canAccess)
    #expect(WindowAccessReport(trustedAPI: true, query: .unavailable).canAccess)
    #expect(!WindowAccessReport(trustedAPI: false, query: .unavailable).canAccess)
}
@Test func windowHelperRejectsMalformedOversizedOrWrongProtocolReplies() throws {
    let value = WindowHelperState(enabled: true, busy: false, phase: .permission,
        permission: WindowAccessReport(trustedAPI: false, query: .denied), savedAt: nil, backupAt: nil,
        pending: false, processID: 123)
    let data = try JSONEncoder().encode(value)
    #expect(WindowHelperState.decode(data)?.permission.query == .denied)
    var wrong = value; wrong.version = 999
    #expect(WindowHelperState.decode(try JSONEncoder().encode(wrong)) == nil)
    wrong = value; wrong.processID = 0
    #expect(WindowHelperState.decode(try JSONEncoder().encode(wrong)) == nil)
    #expect(WindowHelperState.decode(Data(repeating: 0, count: 65_536)) == nil)
    #expect(WindowLayoutTransfer.decode(Data(repeating: 0, count: WindowHelperEndpoint.maximumTransferBytes + 1)) == nil)
}

@Test @MainActor func unavailableWindowHelperReportsFailureWithoutXPCQueueCrashOrAutomaticRepair() async throws {
    let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: WindowLayoutClient.enabledKey)
    defaults.set("new", forKey: HelperServiceKind.window.revisionKey)
    let snapshot = Data("saved sentinel".utf8)
    defaults.set(snapshot, forKey: "windowLayout.current.v1")
    let registration = FakeFanHelperRegistration(status: .enabled)
    let client = WindowLayoutClient(defaults: defaults, revision: "new", registrationService: registration,
        connectionFactory: { (NSXPCConnection(machServiceName: name), "identifier \"local.lookout.app\"") })
    defer { client.stop() }
    for _ in 0..<200 where client.connecting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!client.connecting && !client.connected && client.connectionError != nil)
    #expect(registration.registrations == 0 && registration.unregistrations == 0)
    #expect(defaults.data(forKey: "windowLayout.current.v1") == snapshot)
}

private final class WindowRecoveryProxy: NSObject, WindowHelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let allowed: Bool
    init(allowed: Bool) { self.allowed = allowed }
    var actions: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func respond(_ action: String, _ reply: @escaping @Sendable (Data?) -> Void) {
        lock.lock(); calls.append(action); lock.unlock()
        let value = WindowHelperState(enabled: true, busy: false, phase: allowed ? .ready : .permission,
            permission: WindowAccessReport(trustedAPI: allowed, query: allowed ? .allowed : .denied),
            savedAt: nil, backupAt: nil, pending: false, processID: 123)
        reply(try? JSONEncoder().encode(value))
    }
    func configure(_ enabled: Bool, legacy: Data?, reply: @escaping @Sendable (Data?) -> Void) { respond("configure", reply) }
    func status(reply: @escaping @Sendable (Data?) -> Void) { respond("status", reply) }
    func perform(_ action: String, reply: @escaping @Sendable (Data?) -> Void) { respond(action, reply) }
}
@Test @MainActor func windowRecoveryChecksExistingAccessWithoutReregisteringAndOnlyRequestsMissingPermission() async throws {
    for allowed in [true, false] {
        let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: WindowLayoutClient.enabledKey)
        defaults.set("same", forKey: HelperServiceKind.window.revisionKey)
        let registration = FakeFanHelperRegistration(status: .enabled)
        let proxy = WindowRecoveryProxy(allowed: allowed)
        let client = WindowLayoutClient(defaults: defaults, revision: "same", registrationService: registration,
            requestOverride: { action, enabled, legacy in
                await withCheckedContinuation { continuation in
                    if let action { proxy.perform(action) { continuation.resume(returning: $0) } }
                    else { proxy.configure(enabled, legacy: legacy) { continuation.resume(returning: $0) } }
                }
            })
        defer { client.stop() }
        for _ in 0..<100 where client.busy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(client.connected && client.trusted == allowed)
        #expect(!proxy.actions.contains("permission")) // Opening settings is never enough to prompt.
        client.install()
        for _ in 0..<100 where client.busy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(proxy.actions.last == (allowed ? "refresh" : "permission"))
        #expect(registration.registrations == 0 && registration.unregistrations == 0)
    }
}
@Test @MainActor func windowRecoveryReconnectsThenChecksPermissionAfterOneExplicitSetup() async throws {
    for allowed in [true, false] {
        let (name, defaults) = try windowDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: WindowLayoutClient.enabledKey)
        defaults.set("old", forKey: HelperServiceKind.window.revisionKey)
        let registration = FakeFanHelperRegistration(status: .enabled)
        let proxy = WindowRecoveryProxy(allowed: allowed)
        let client = WindowLayoutClient(defaults: defaults, revision: "new", registrationService: registration,
            settle: { await Task.yield() }, requestOverride: { action, enabled, legacy in
                await withCheckedContinuation { continuation in
                    if let action { proxy.perform(action) { continuation.resume(returning: $0) } }
                    else { proxy.configure(enabled, legacy: legacy) { continuation.resume(returning: $0) } }
                }
            })
        defer { client.stop() }
        client.install(); client.install()
        for _ in 0..<100 where !client.connected || client.busy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(client.connected && client.trusted == allowed)
        #expect(registration.registrations == 1 && registration.unregistrations == 1)
        #expect(proxy.actions.filter { $0 == "permission" }.count == (allowed ? 0 : 1))
        client.refresh()
        for _ in 0..<100 where client.busy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(proxy.actions.filter { $0 == "permission" }.count == (allowed ? 0 : 1))
    }
}
