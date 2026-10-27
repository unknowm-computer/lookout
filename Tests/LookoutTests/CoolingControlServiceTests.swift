import Foundation
import ServiceManagement
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func unavailableFanHelperReturnsToSystemWithoutCrashingOnXPCBackgroundQueue() async throws {
    let name = "LookoutTests.fanXPC.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("fixture", forKey: "fanHelperRevision.v1")
    let registration = FakeFanHelperRegistration(status: .enabled)
    let control = CoolingControlService(defaults: defaults, helperRevision: "fixture", registrationService: registration,
        helperSettle: { await Task.yield() },
        connectionFactory: {
            (NSXPCConnection(machServiceName: name, options: .privileged), "identifier \"local.lookout.app\"")
        })
    control.select(.comfortable)
    for _ in 0..<60 where control.busy { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!control.busy)
    #expect(control.appliedMode == .system)
    #expect(control.message != nil || control.helperError != nil)
    #expect(registration.registrations == 1)
    #expect(registration.unregistrations == 1)
    #expect(control.helperPreviouslyEnabled)
    #expect(defaults.string(forKey: "coolingMode.v1") == nil)
    control.stop()
}

@Test @MainActor func savedCoolingModeWaitsForAutomaticHelperUpdate() async throws {
    enum Failure: Error { case fixture }
    let name = "LookoutTests.fanResume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
    defaults.set("intensive", forKey: "coolingMode.v1")
    let registration = FakeFanHelperRegistration(status: .enabled)
    var release: CheckedContinuation<Void, Never>?
    var settles = 0, connections = 0
    let control = CoolingControlService(defaults: defaults, helperRevision: "new", registrationService: registration,
        helperSettle: {
            settles += 1
            if settles == 1 { await withCheckedContinuation { release = $0 } }
        }, connectionFactory: { connections += 1; throw Failure.fixture })
    control.prepareHelperAfterUpdate()
    for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
    let continuation = try #require(release)
    let reading = CoolingReading(cpu: 60, gpu: 55, fans: [], uptime: 0, canControl: true)
    control.pulse(reading: reading, enabled: true)
    #expect(connections == 0 && control.updatingHelper)
    continuation.resume()
    for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
    control.pulse(reading: reading, enabled: true)
    for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(connections == 1 && registration.registrations == 1)
    #expect(defaults.string(forKey: "coolingMode.v1") == "intensive")
    control.stop()
}

@Test @MainActor func selectionQueuedDuringHelperUpdateIsCancelledWhenMonitoringStops() async throws {
    enum Failure: Error { case fixture }
    for cancelled in [false, true] {
        let name = "LookoutTests.fanPending.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old", forKey: FanHelperMaintenance.revisionKey)
        let registration = FakeFanHelperRegistration(status: .enabled)
        var release: CheckedContinuation<Void, Never>?
        var settles = 0, connections = 0
        let control = CoolingControlService(defaults: defaults, helperRevision: "new", registrationService: registration,
            helperSettle: {
                settles += 1
                if settles == 1 { await withCheckedContinuation { release = $0 } }
            }, connectionFactory: { connections += 1; throw Failure.fixture })
        control.prepareHelperAfterUpdate()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try #require(release)
        control.select(.intensive)
        if cancelled { control.stop() }
        continuation.resume()
        for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(connections == (cancelled ? 0 : 1))
        #expect(registration.registrations == 1)
        #expect(defaults.string(forKey: "coolingMode.v1") == nil)
        control.stop()
    }
}

@Test @MainActor func pendingApprovalResumesSelectionUnlessUserChoosesSystemAutomatic() async throws {
    enum Failure: Error { case fixture }
    for cancelled in [false, true] {
        let name = "LookoutTests.fanApproval.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("fixture", forKey: FanHelperMaintenance.revisionKey)
        let registration = FakeFanHelperRegistration(status: .requiresApproval)
        var connections = 0
        let control = CoolingControlService(defaults: defaults, helperRevision: "fixture", registrationService: registration,
            helperSettle: { await Task.yield() }, connectionFactory: { connections += 1; throw Failure.fixture })
        control.select(.intensive)
        #expect(connections == 0 && registration.registrations == 0)
        if cancelled {
            control.select(.system)
            for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
        }
        registration.status = .enabled
        control.prepareHelperAfterUpdate()
        for _ in 0..<100 where control.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(connections == (cancelled ? 0 : 1))
        #expect(registration.registrations == 1)
        control.stop()
    }
}
