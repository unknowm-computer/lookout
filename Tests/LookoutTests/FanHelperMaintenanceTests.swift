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

@MainActor private func maintenanceDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "LookoutTests.maintenance.\(UUID().uuidString)"))
}
@MainActor private func waitForMaintenance(_ helper: FanHelperMaintenance) async {
    for _ in 0..<100 where helper.updating { try? await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func helperDoesNotEnrollNewUsersEvenWithASavedCoolingMode() throws {
    let defaults = try maintenanceDefaults()
    defaults.set("intensive", forKey: "coolingMode.v1")
    let service = FakeFanHelperRegistration(status: .notRegistered)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.checkForUpdate(); helper.checkForUpdate()
    #expect(!helper.previouslyEnabled && !helper.updating)
    #expect(service.registrations == 0 && service.unregistrations == 0)
    #expect(!defaults.bool(forKey: FanHelperMaintenance.enabledKey))
}

@Test @MainActor func helperUpdatesLegacyRegistrationOnceAndCoalescesActivationEvents() async throws {
    let defaults = try maintenanceDefaults()
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    var ready = 0; helper.onReady = { ready += 1 }
    helper.checkForUpdate(); helper.checkForUpdate(); helper.checkForUpdate()
    await waitForMaintenance(helper)
    helper.checkForUpdate(); helper.checkForUpdate()
    #expect(service.registrations == 1 && service.unregistrations == 1)
    #expect(ready == 1 && !helper.needsRefresh && helper.error == nil)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "new")
    #expect(defaults.bool(forKey: FanHelperMaintenance.enabledKey))
}

@Test @MainActor func helperRepairsMissingRegistrationOnlyForPreviouslyEnabledUsers() async throws {
    let defaults = try maintenanceDefaults()
    defaults.set(true, forKey: FanHelperMaintenance.enabledKey)
    let service = FakeFanHelperRegistration(status: .notRegistered)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.checkForUpdate(); await waitForMaintenance(helper)
    #expect(service.registrations == 1 && service.unregistrations == 0)
    #expect(helper.status == .enabled)
}

@Test @MainActor func helperNeverOverridesOSConsentAndFinishesAfterApprovalAcrossRelaunch() async throws {
    let defaults = try maintenanceDefaults()
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .requiresApproval)
    let waiting = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    waiting.checkForUpdate(); waiting.checkForUpdate()
    #expect(service.registrations == 0 && service.unregistrations == 0)
    #expect(waiting.status == .requiresApproval && waiting.error == nil)
    service.status = .enabled
    let resumed = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    resumed.checkForUpdate(); await waitForMaintenance(resumed)
    resumed.checkForUpdate()
    #expect(service.registrations == 1 && service.unregistrations == 1)
    #expect(resumed.status == .enabled && !resumed.needsRefresh)
}

@Test @MainActor func helperWaitsForNewOSApprovalWithoutRegisteringRepeatedly() async throws {
    let defaults = try maintenanceDefaults()
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    service.registerStatus = .requiresApproval
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.checkForUpdate(); await waitForMaintenance(helper)
    for _ in 0..<5 { helper.checkForUpdate() }
    #expect(service.registrations == 1 && service.unregistrations == 1)
    #expect(helper.status == .requiresApproval && !helper.updating && helper.error == nil)
    service.status = .enabled; service.registerStatus = .enabled
    helper.checkForUpdate(); await waitForMaintenance(helper)
    helper.checkForUpdate()
    #expect(service.registrations == 2 && service.unregistrations == 2)
    #expect(helper.status == .enabled && !helper.needsRefresh)
}

@Test @MainActor func helperFailureIsBoundedAndCanBeRetriedExplicitly() async throws {
    enum Failure: Error { case registration }
    let defaults = try maintenanceDefaults()
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    service.registerStatus = .notRegistered; service.registerError = Failure.registration
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.checkForUpdate(); await waitForMaintenance(helper)
    for _ in 0..<5 { helper.checkForUpdate() }
    #expect(service.registrations == 1 && helper.error != nil)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "old")
    service.registerError = nil; service.registerStatus = .enabled
    helper.activate(); await waitForMaintenance(helper)
    #expect(service.registrations == 2 && helper.error == nil && !helper.needsRefresh)
}

@Test @MainActor func helperConnectionRepairRunsAtMostOncePerLaunch() async throws {
    let defaults = try maintenanceDefaults()
    defaults.set("new", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    #expect(helper.repairOnce())
    await waitForMaintenance(helper)
    #expect(!helper.repairOnce())
    #expect(service.registrations == 1 && service.unregistrations == 1)
    #expect(helper.error != nil)
}

@Test @MainActor func helperRejectsMissingAppSignatureWithoutRegistering() throws {
    let defaults = try maintenanceDefaults()
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let service = FakeFanHelperRegistration(status: .enabled)
    let helper = FanHelperMaintenance(defaults: defaults, revision: nil, service: service, settle: { await Task.yield() })
    helper.checkForUpdate()
    #expect(service.registrations == 0 && service.unregistrations == 0)
    #expect(helper.error != nil && !helper.updating)
}

@Test @MainActor func firstHelperActivationStillNeedsAnExplicitAction() async throws {
    let defaults = try maintenanceDefaults()
    let service = FakeFanHelperRegistration(status: .notRegistered)
    let helper = FanHelperMaintenance(defaults: defaults, revision: "new", service: service, settle: { await Task.yield() })
    helper.activate(); await waitForMaintenance(helper)
    #expect(defaults.bool(forKey: FanHelperMaintenance.enabledKey))
    #expect(service.registrations == 1 && helper.status == .enabled)
}
