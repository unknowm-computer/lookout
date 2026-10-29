import Foundation
import ServiceManagement
@testable import Lookout
import Testing

@MainActor final class FakeFanHelperRegistration: FanHelperRegistering {
    var status: SMAppService.Status
    var registerStatus: SMAppService.Status = .enabled
    var registerError: Error?
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    init(status: SMAppService.Status) { self.status = status }
    func register() throws {
        registrations += 1; status = registerStatus
        if let registerError { throw registerError }
    }
    func unregister() async throws {
        unregistrations += 1; status = .notRegistered
        await Task.yield()
    }
}

@MainActor private func maintenanceDefaults() throws -> (String, UserDefaults) {
    let name = "LookoutTests.maintenance.\(UUID().uuidString)"
    return (name, try #require(UserDefaults(suiteName: name)))
}
@MainActor private func waitForMaintenance(_ helper: FanHelperMaintenance) async {
    for _ in 0..<100 where helper.updating { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(!helper.updating)
}

@Test @MainActor func helperStatusChecksDoNotEnrollNewUsersEvenWithASavedCoolingMode() throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("intensive", forKey: "coolingMode.v1")
    let service = FakeFanHelperRegistration(status: .notRegistered)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service)
    helper.refresh(); helper.refresh()
    #expect(!helper.updating && helper.status == .notRegistered)
    #expect(service.registrations == 0 && service.unregistrations == 0)
    #expect(!defaults.bool(forKey: FanHelperMaintenance.enabledKey))
}
@Test @MainActor func helperStaleOrMissingRegistrationIsOnlyReportedWithoutAutomaticRepair() throws {
    for status in [SMAppService.Status.enabled, .notRegistered, .notFound] {
        let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
        let service = FakeFanHelperRegistration(status: status)
        let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service)
        for _ in 0..<10 { helper.refresh() }
        #expect(service.registrations == 0 && service.unregistrations == 0)
        #expect(helper.status == status && helper.needsRefresh == (status == .enabled))
        #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "old")
    }
}
@Test @MainActor func helperApprovalChangeAndRelaunchOnlyRefreshStatus() throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .requiresApproval)
    let waiting = FanHelperMaintenance(defaults: defaults, revision: "new", service: service)
    waiting.refresh(); waiting.activate()
    #expect(service.registrations == 0 && service.unregistrations == 0)
    service.status = .enabled
    let resumed = FanHelperMaintenance(defaults: defaults, revision: "new", service: service)
    resumed.refresh(); resumed.refresh()
    #expect(resumed.status == .enabled && resumed.needsRefresh)
    #expect(service.registrations == 0 && service.unregistrations == 0)
}
@Test @MainActor func helperExplicitUpdateRunsOnceForRepeatedButtonPresses() async throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.activate(); helper.activate(); helper.activate()
    await waitForMaintenance(helper)
    for _ in 0..<5 { helper.refresh() }
    #expect(service.registrations == 1 && service.unregistrations == 1)
    #expect(!helper.needsRefresh && helper.error == nil)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "new")
}
@Test @MainActor func helperExplicitSetupWaitsForApprovalWithoutAnotherRegistrationAfterGrant() async throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = FakeFanHelperRegistration(status: .notRegistered)
    service.registerStatus = .requiresApproval
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.activate(); await waitForMaintenance(helper)
    helper.activate(); helper.refresh()
    #expect(service.registrations == 1 && service.unregistrations == 0)
    #expect(helper.status == .requiresApproval && helper.error == nil)
    service.status = .enabled
    helper.refresh(); helper.refresh()
    #expect(service.registrations == 1 && service.unregistrations == 0)
    #expect(!helper.needsRefresh && helper.status == .enabled)
}
@Test @MainActor func helperRegistrationFailureRequiresAnotherExplicitButtonPress() async throws {
    enum Failure: Error { case registration }
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    service.registerStatus = .notRegistered; service.registerError = Failure.registration
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.activate(); await waitForMaintenance(helper)
    for _ in 0..<10 { helper.refresh() }
    #expect(service.registrations == 1 && service.unregistrations == 1 && helper.error != nil)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "old")
    service.registerError = nil; service.registerStatus = .enabled
    helper.activate(); await waitForMaintenance(helper)
    #expect(service.registrations == 2 && helper.error == nil && !helper.needsRefresh)
}
@Test @MainActor func helperRejectsExplicitSetupWhenAppSignatureIsUnavailable() throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: nil, service: service)
    helper.refresh(); helper.activate()
    #expect(service.registrations == 0 && service.unregistrations == 0)
    #expect(helper.error != nil && !helper.updating)
}
@Test @MainActor func firstHelperActivationRemainsAnExplicitAction() async throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = FakeFanHelperRegistration(status: .notRegistered)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.refresh(); #expect(service.registrations == 0)
    helper.activate(); await waitForMaintenance(helper)
    #expect(defaults.bool(forKey: FanHelperMaintenance.enabledKey))
    #expect(service.registrations == 1 && helper.status == .enabled)
}
@Test @MainActor func obsoleteApprovalFlagDoesNotTriggerAutomaticReregistration() throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("new", forKey: FanHelperMaintenance.revisionKey)
    defaults.set(true, forKey: "fanHelperApprovalPending.v1")
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service)
    for _ in 0..<10 { helper.refresh() }
    #expect(service.registrations == 0 && service.unregistrations == 0 && !helper.needsRefresh)
}
@Test @MainActor func approvalChangeDuringExplicitSetupDoesNotIssueAnotherRegister() async throws {
    let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service,
                                     settle: { service.status = .requiresApproval })
    helper.activate(); await waitForMaintenance(helper)
    #expect(service.unregistrations == 1 && service.registrations == 0)
    #expect(helper.status == .requiresApproval && helper.error == nil)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "old")
}

@Test @MainActor func unchangedHelperRegistrationIsPreservedForBothFeatures() async throws {
    for kind in [HelperServiceKind.fan, .window] {
        let (name, defaults) = try maintenanceDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let revision = HelperRevision.fingerprint(requirement: "same helper", launchConfiguration: Data("same launch plist".utf8))
        defaults.set(revision, forKey: kind.revisionKey)
        let service = FakeFanHelperRegistration(status: .enabled)
        let helper = FanHelperMaintenance(defaults: defaults, revision: revision, kind: kind, service: service, settle: { await Task.yield() })
        helper.refresh(); helper.activate(); await waitForMaintenance(helper)
        #expect(!helper.needsRefresh && service.registrations == 0 && service.unregistrations == 0)
        helper.activate(force: true); await waitForMaintenance(helper)
        #expect(service.registrations == 1 && service.unregistrations == 1)
        #expect(defaults.string(forKey: kind.revisionKey) == revision)
    }
}
@Test func helperRevisionTracksHelperAndLaunchConfigurationInsteadOfAppVersion() {
    let plist = Data("launch configuration".utf8)
    let revision = HelperRevision.fingerprint(requirement: "signed helper", launchConfiguration: plist)
    #expect(revision == HelperRevision.fingerprint(requirement: "signed helper", launchConfiguration: plist))
    #expect(revision != HelperRevision.fingerprint(requirement: "updated helper", launchConfiguration: plist))
    #expect(revision != HelperRevision.fingerprint(requirement: "signed helper", launchConfiguration: Data("new launch configuration".utf8)))
}
