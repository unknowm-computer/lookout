import Foundation
import ServiceManagement
import LookoutCore
@testable import Lookout
import Testing

@MainActor private func waitForCooling(_ control: CoolingControlService) async throws {
    for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!control.busy)
}
private func controlReading() -> CoolingReading {
    CoolingReading(cpu: 60, gpu: 55, fans: [], uptime: 0, canControl: true)
}

@Test @MainActor func unavailableFanHelperStopsWithoutAutomaticRepairOrXPCQueueCrash() async throws {
    let name = "LookoutTests.fanXPC.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("fixture", forKey: FanHelperMaintenance.revisionKey)
    let registration = FakeFanHelperRegistration(status: .enabled)
    let control = CoolingControlService(defaults: defaults, helperRevision: "fixture", registrationService: registration,
        connectionFactory: { (NSXPCConnection(machServiceName: name, options: .privileged), "identifier \"local.lookout.app\"") })
    control.select(.comfortable)
    try await waitForCooling(control)
    #expect(control.appliedMode == .system && control.message != nil)
    for _ in 0..<5 { control.refresh(); control.pulse(reading: controlReading(), enabled: true) }
    #expect(registration.registrations == 0 && registration.unregistrations == 0)
    #expect(defaults.string(forKey: "coolingMode.v1") == nil)
    control.stop()
}
@Test @MainActor func savedCoolingModeWaitsForUserRequestedHelperUpdate() async throws {
    enum Failure: Error { case fixture }
    let name = "LookoutTests.fanResume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey); defaults.set("intensive", forKey: "coolingMode.v1")
    let registration = FakeFanHelperRegistration(status: .enabled)
    var release: CheckedContinuation<Void, Never>?
    var settles = 0, connections = 0
    let control = CoolingControlService(defaults: defaults, helperRevision: "new", registrationService: registration,
        helperSettle: {
            settles += 1
            if settles == 1 { await withCheckedContinuation { release = $0 } }
        }, connectionFactory: { connections += 1; throw Failure.fixture })
    for _ in 0..<5 { control.refresh(); control.prepareToResume(); control.pulse(reading: controlReading(), enabled: true) }
    #expect(connections == 0 && registration.registrations == 0 && control.needsRefresh)
    control.install()
    for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
    let continuation = try #require(release)
    control.pulse(reading: controlReading(), enabled: true)
    #expect(connections == 0 && control.updatingHelper)
    continuation.resume(); try await waitForCooling(control)
    control.pulse(reading: controlReading(), enabled: true); try await waitForCooling(control)
    #expect(connections == 1 && registration.registrations == 1 && registration.unregistrations == 1)
    #expect(defaults.string(forKey: "coolingMode.v1") == "intensive")
    control.stop()
}
@Test @MainActor func stoppingDuringManualSetupCancelsSavedModeRestoration() async throws {
    enum Failure: Error { case fixture }
    for cancelled in [false, true] {
        let name = "LookoutTests.fanPending.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old", forKey: FanHelperMaintenance.revisionKey); defaults.set("comfortable", forKey: "coolingMode.v1")
        let registration = FakeFanHelperRegistration(status: .enabled)
        var release: CheckedContinuation<Void, Never>?
        var settles = 0, connections = 0
        let control = CoolingControlService(defaults: defaults, helperRevision: "new", registrationService: registration,
            helperSettle: {
                settles += 1
                if settles == 1 { await withCheckedContinuation { release = $0 } }
            }, connectionFactory: { connections += 1; throw Failure.fixture })
        control.install()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try #require(release)
        if cancelled { control.stop() }
        continuation.resume(); try await waitForCooling(control)
        control.pulse(reading: controlReading(), enabled: true); try await waitForCooling(control)
        #expect(connections == (cancelled ? 0 : 1))
        #expect(registration.registrations == 1 && defaults.string(forKey: "coolingMode.v1") == "comfortable")
        control.stop()
    }
}
@Test @MainActor func blockedSelectionDoesNotQueueModeOrRegisterAfterPermissionGrant() async throws {
    enum Failure: Error { case fixture }
    let name = "LookoutTests.fanApproval.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("fixture", forKey: FanHelperMaintenance.revisionKey)
    let registration = FakeFanHelperRegistration(status: .requiresApproval)
    var connections = 0
    let control = CoolingControlService(defaults: defaults, helperRevision: "fixture", registrationService: registration,
        connectionFactory: { connections += 1; throw Failure.fixture })
    control.select(.intensive)
    #expect(connections == 0 && control.message != nil)
    registration.status = .enabled; control.refresh()
    control.pulse(reading: controlReading(), enabled: true); try await waitForCooling(control)
    #expect(connections == 0 && registration.registrations == 0 && registration.unregistrations == 0)
    control.select(.intensive); try await waitForCooling(control)
    #expect(connections == 1 && registration.registrations == 0)
    control.stop()
}
@Test @MainActor func permissionGrantAllowsSavedModeWithoutAdditionalHelperRegistration() async throws {
    enum Failure: Error { case fixture }
    let name = "LookoutTests.fanGranted.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("fixture", forKey: FanHelperMaintenance.revisionKey); defaults.set("comfortable", forKey: "coolingMode.v1")
    let registration = FakeFanHelperRegistration(status: .requiresApproval)
    var connections = 0
    let control = CoolingControlService(defaults: defaults, helperRevision: "fixture", registrationService: registration,
        connectionFactory: { connections += 1; throw Failure.fixture })
    control.refresh(); control.pulse(reading: controlReading(), enabled: true)
    #expect(connections == 0)
    registration.status = .enabled; control.refresh()
    control.pulse(reading: controlReading(), enabled: true); try await waitForCooling(control)
    #expect(connections == 1 && registration.registrations == 0 && registration.unregistrations == 0)
    for _ in 0..<5 { control.refresh(); control.pulse(reading: controlReading(), enabled: true) }
    #expect(connections == 1)
    control.stop()
}
@Test @MainActor func selectingCustomModeWithStaleRegistrationOnlyShowsGuidance() throws {
    enum Failure: Error { case fixture }
    let name = "LookoutTests.fanStale.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    let registration = FakeFanHelperRegistration(status: .enabled)
    var connections = 0
    let control = CoolingControlService(defaults: defaults, helperRevision: "new", registrationService: registration,
        connectionFactory: { connections += 1; throw Failure.fixture })
    control.select(.comfortable); control.refresh()
    #expect(connections == 0 && control.needsRefresh && control.message != nil && !control.busy)
    #expect(registration.registrations == 0 && registration.unregistrations == 0)
    #expect(defaults.string(forKey: FanHelperMaintenance.revisionKey) == "old")
    control.stop()
}
