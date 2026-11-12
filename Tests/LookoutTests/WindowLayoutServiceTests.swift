import AppKit
import Foundation
import LookoutCore
import WindowHelperProtocol
@testable import WindowLayoutRuntime
import Testing

@MainActor private final class LayoutBackendFixture: WindowLayoutBackend {
    var permission = true
    var permissionChecks = 0
    var isTrusted: Bool { permissionChecks += 1; return permission }
    var screens: [LayoutDisplay]
    var candidate: WindowLayoutSnapshot?
    var captures = 0
    var reads = 0
    var restores: [[LayoutWindow]] = []
    var identityScopes: [[LayoutWindow]] = []
    var results: [WindowRestoreResult] = []
    var onRestore: (() -> Void)?
    init(_ value: WindowLayoutSnapshot) { screens = value.displays; candidate = value }
    func displays() -> [LayoutDisplay] { reads += 1; return screens }
    func capture(timeBudget: TimeInterval) -> WindowLayoutSnapshot? { captures += 1; return candidate }
    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay], identityScope: [LayoutWindow]) -> WindowRestoreResult {
        restores.append(windows)
        identityScopes.append(identityScope)
        onRestore?()
        return results.isEmpty ? WindowRestoreResult(restored: windows.count) : results.removeFirst()
    }
}
private func layoutFixture() -> WindowLayoutSnapshot {
    let frame = LayoutRect(x: 0, y: 0, width: 1440, height: 900)
    return WindowLayoutSnapshot(displays: [LayoutDisplay(id: "screen", frame: frame, visibleFrame: frame)],
        windows: [LayoutWindow(bundleID: "fixture", pid: 123, launchDate: Date(), identifier: "one", title: "Window",
                               displayID: "screen", frame: LayoutRect(x: 10, y: 30, width: 500, height: 400))])
}
@MainActor private func finish(_ service: WindowLayoutService) async throws {
    for _ in 0..<150 where service.busy { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!service.busy)
}
@MainActor private func layoutDefaults() -> (String, UserDefaults) {
    let name = "LookoutTests.layout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(WindowBootSession.currentID(), forKey: WindowLayoutService.bootSessionKey)
    return (name, defaults)
}

@Test @MainActor func windowLayoutDefaultsOffAndDoesNoAXOrPollingWork() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let backend = LayoutBackendFixture(layoutFixture())
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false)
    defer { service.stop() }
    service.refresh(); service.willSleep(); service.didWake(); service.displaysChanged(); service.restoreNow()
    try await Task.sleep(for: .milliseconds(10))
    #expect(!service.enabled && !service.busy)
    #expect(backend.permissionChecks == 0 && backend.reads == 0 && backend.captures == 0 && backend.restores.isEmpty)
    #expect(defaults.object(forKey: WindowLayoutService.enabledKey) == nil)
}
@Test @MainActor func windowLayoutEnablingWithoutPermissionDoesNotCaptureOrPrompt() {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let backend = LayoutBackendFixture(layoutFixture()); backend.permission = false
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false)
    defer { service.stop() }
    service.setEnabled(true); service.willSleep(); service.didWake()
    #expect(service.enabled && service.status == .permission)
    #expect(backend.reads == 0 && backend.captures == 0 && backend.restores.isEmpty)
}
@Test @MainActor func windowLayoutSavesBeforeSleepRotatesBackupAndRestoresOnlyOnWake() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let first = layoutFixture(), backend = LayoutBackendFixture(first)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 3
    try await finish(service)
    #expect(service.current == first && backend.captures == 1)
    var next = first; next.windows[0].frame.x = 70; backend.candidate = next
    service.willSleep()
    #expect(service.current == next && service.lastGood == first && service.pending)
    #expect(backend.restores.isEmpty)
    service.willSleep() // Duplicate notification must not overwrite the protected snapshot.
    #expect(backend.captures == 2)
    service.didWake(); try await finish(service)
    #expect(backend.restores == [next.windows] && !service.pending)
    #expect(service.status == .restored(1, 0))
    let reads = backend.reads
    try await Task.sleep(for: .milliseconds(15))
    #expect(backend.reads == reads) // No recurring idle timer.
}
@Test(arguments: [false, true])
@MainActor func windowLayoutFreezesSnapshotWhenDisplayDisconnectPrecedesSleep(otherDisplayRemains: Bool) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 20
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), attempts: 5, now: { uptime })
    defer { service.stop() }
    var otherDisplay = saved.displays[0]; otherDisplay.id = "other"
    backend.screens = otherDisplayRemains ? [otherDisplay] : []
    service.displaysChanged(); uptime = 24; service.willSleep(); service.didWake()
    try await finish(service)
    #expect(service.current == saved && service.pending && backend.captures == 0 && backend.restores.isEmpty)
    #expect(service.status == .waiting)
    backend.screens = saved.displays
    service.refresh(); try await finish(service)
    #expect(backend.restores == [saved.windows] && !service.pending)
}
@Test @MainActor func windowLayoutCorruptCurrentFallsBackToIndependentBackupAfterRelaunch() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let backup = layoutFixture(), backend = LayoutBackendFixture(backup)
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(true, forKey: WindowLayoutService.pendingKey)
    defaults.set(true, forKey: WindowLayoutService.restoreKey)
    defaults.set(Data("broken".utf8), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(backup), forKey: WindowLayoutService.backupKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    try await finish(service)
    #expect(service.current == nil && service.lastGood == backup)
    #expect(backend.restores == [backup.windows] && backend.captures == 0)
}
@Test @MainActor func windowLayoutRetriesOnlyFailedWindowsAndKeepsSnapshotsUntilNextSave() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    var saved = layoutFixture(); var second = saved.windows[0]; second.id = UUID(); second.identifier = "two"
    saved.windows.append(second)
    let backend = LayoutBackendFixture(saved)
    backend.results = [WindowRestoreResult(restored: 1, failed: [second]), WindowRestoreResult(failed: [second])]
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); try await finish(service)
    #expect(backend.restores == [saved.windows, [second]])
    #expect(service.pending && service.status == .incomplete)
    #expect(backend.captures == 0 && service.current == saved)
}
@Test @MainActor func windowLayoutDisableCancelsWakeAndPreservesProtectionForNextLaunch() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(2))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); service.setEnabled(false)
    try await Task.sleep(for: .milliseconds(15))
    #expect(!service.busy && service.status == .disabled && service.pending && backend.restores.isEmpty)
    #expect(defaults.bool(forKey: WindowLayoutService.pendingKey))
    service.didWake(); service.setEnabled(true); try await finish(service)
    #expect(backend.restores == [saved.windows])
}
@Test @MainActor func windowLayoutRejectsInvalidCaptureAndPermissionRevocationWithoutOverwriting() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    var uptime: TimeInterval = 0
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 10
    var invalid = saved
    invalid.windows.removeAll()
    backend.candidate = invalid
    service.willSleep()
    #expect(service.current == saved && service.lastGood == nil && service.status == .captureFailed)
    service.didWake(); backend.permission = false; try await finish(service)
    #expect(service.status == .permission && service.pending && backend.restores.isEmpty)
}
@Test @MainActor func windowLayoutExplicitRelearnKeepsOldLayoutAndFailedRelearnKeepsProtection() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    var uptime: TimeInterval = 0
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 3; backend.screens = []; service.displaysChanged()
    backend.candidate = nil; service.useCurrentLayout()
    #expect(service.pending && service.status == .captureFailed && service.current == saved && service.lastGood == nil)
    var new = saved; new.displays[0].id = "new"; new.windows[0].displayID = "new"
    backend.screens = new.displays; backend.candidate = new
    service.useCurrentLayout()
    #expect(!service.pending && service.current == new && service.lastGood == saved)
    service.restoreNow(previous: true); service.stop()
    #expect(service.current == new && service.lastGood == saved)
}

@Test @MainActor func manualWindowSaveReplacesPendingRestoreAndPersistsTheNewDate() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture()
    var fresh = saved
    fresh.date = saved.date.addingTimeInterval(600)
    fresh.windows[0].frame.x += 100
    fresh.savedWithOmissions = true
    let backend = LayoutBackendFixture(fresh)
    // The Dock work area can change while the user is confirming the save.
    backend.screens[0].visibleFrame.height -= 30
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(true, forKey: WindowLayoutService.pendingKey)
    defaults.set(true, forKey: WindowLayoutService.restoreKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }

    #expect(service.busy && service.pending)
    service.useCurrentLayout()
    let report = service.report()
    #expect(report.phase == .saved && report.savedAt == fresh.date && report.backupAt == saved.date)
    #expect(report.savedWithOmissions == true && report.restoreReport == nil)
    #expect(!report.busy && !report.pending && !defaults.bool(forKey: WindowLayoutService.restoreKey))
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == fresh)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.backupKey)) == saved)
    try await Task.sleep(for: .milliseconds(15))
    #expect(backend.restores.isEmpty && backend.captures == 1)
}

@Test @MainActor func windowLayoutDoesNotWriteUntilAllDisplaysRemainStable() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(10), attempts: 12)
    defer { service.stop() }
    service.setEnabled(true); backend.screens = []; service.willSleep(); service.didWake()
    try await Task.sleep(for: .milliseconds(25))
    #expect(backend.restores.isEmpty && service.pending)
    backend.screens = saved.displays
    try await Task.sleep(for: .milliseconds(12))
    #expect(backend.restores.isEmpty)
    try await finish(service)
    #expect(backend.restores == [saved.windows])
}
@Test @MainActor func windowLayoutClosedWindowsAreSkippedWithoutBlockingFutureAutomaticSaves() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    backend.results = [WindowRestoreResult(skipped: 1)]
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); try await finish(service)
    #expect(!service.pending && service.status == .restored(0, 1))
}
@Test @MainActor func windowLayoutSuccessfulBackupRestoreBecomesActiveWithoutLosingNewerLayout() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(); var previous = saved; previous.windows[0].frame.x = 200
    let backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(previous), forKey: WindowLayoutService.backupKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(previous: true); try await finish(service)
    #expect(backend.restores == [previous.windows])
    #expect(service.current == previous && service.lastGood == saved && !service.pending)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == previous)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.backupKey)) == saved)
}

@Test @MainActor func windowLayoutOrdinaryDisplayChangeProtectsWithoutMovingWindowsOnFocus() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true)
    backend.screens[0].frame.x = 80; backend.screens[0].visibleFrame.x = 80
    service.displaysChanged(); service.refresh()
    try await Task.sleep(for: .milliseconds(15))
    #expect(service.pending && !service.busy && backend.restores.isEmpty)
    #expect(!defaults.bool(forKey: WindowLayoutService.restoreKey))
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == [saved.windows] && !service.pending)
}

@Test @MainActor func windowLayoutWorkspaceEventsSaveBeforeSleepAndIgnoreScreenOnlyWake() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    var uptime: TimeInterval = 0
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: true,
                                      step: .milliseconds(1), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 10
    let center = NSWorkspace.shared.notificationCenter
    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    #expect(!service.pending && backend.captures == 0 && backend.restores.isEmpty)
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(service.pending && backend.captures == 1) // Capture completed within the sleep callback.
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await finish(service)
    #expect(!service.pending && backend.restores == [saved.windows])
    service.stop()
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(!service.pending && backend.captures == 1)
}

@Test @MainActor func windowLayoutNewBootClearsBothSnapshotsAndPendingBeforeCapturingFreshLayout() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(); var fresh = saved; fresh.windows[0].frame.x = 200
    let backend = LayoutBackendFixture(fresh)
    defaults.set("previous-boot", forKey: WindowLayoutService.bootSessionKey)
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.backupKey)
    defaults.set(true, forKey: WindowLayoutService.pendingKey)
    defaults.set(true, forKey: WindowLayoutService.restoreKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), bootSessionID: "current-boot", now: { uptime })
    defer { service.stop() }
    #expect(service.current == nil && service.lastGood == nil && !service.pending)
    #expect(defaults.data(forKey: WindowLayoutService.currentKey) == nil)
    #expect(defaults.data(forKey: WindowLayoutService.backupKey) == nil)
    #expect(!defaults.bool(forKey: WindowLayoutService.pendingKey) && !defaults.bool(forKey: WindowLayoutService.restoreKey))
    #expect(defaults.string(forKey: WindowLayoutService.bootSessionKey) == "current-boot")
    #expect(service.enabled && backend.restores.isEmpty)
    uptime = 3; try await finish(service)
    #expect(service.current == fresh && service.lastGood == nil && backend.captures == 1)
    #expect(backend.restores.isEmpty && !service.pending)
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == [fresh.windows])
}
@Test @MainActor func windowLayoutSameBootRelaunchPreservesBackupAndResumesPendingRestore() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(); var backup = saved; backup.windows[0].frame.x = 150
    let backend = LayoutBackendFixture(saved)
    defaults.set("same-boot", forKey: WindowLayoutService.bootSessionKey)
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(backup), forKey: WindowLayoutService.backupKey)
    defaults.set(true, forKey: WindowLayoutService.pendingKey)
    defaults.set(true, forKey: WindowLayoutService.restoreKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), bootSessionID: "same-boot")
    defer { service.stop() }
    try await finish(service)
    #expect(service.current == saved && service.lastGood == backup && !service.pending)
    #expect(backend.restores == [saved.windows] && backend.captures == 0)
}
@Test @MainActor func windowLayoutUnscopedLegacyOrUnknownBootCannotRestoreEvenManually() throws {
    for bootID in ["new-boot", nil] as [String?] {
        let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.removeObject(forKey: WindowLayoutService.bootSessionKey)
        let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
        defaults.set(true, forKey: WindowLayoutService.enabledKey)
        defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
        defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.backupKey)
        defaults.set(true, forKey: WindowLayoutService.pendingKey)
        defaults.set(true, forKey: WindowLayoutService.restoreKey)
        let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                          startEnabled: false, bootSessionID: bootID)
        defer { service.stop() }
        #expect(!service.enabled && service.snapshot == nil && !service.pending)
        #expect(defaults.bool(forKey: WindowLayoutService.enabledKey))
        #expect(backend.permissionChecks == 0 && backend.captures == 0)
        service.restoreNow(); service.restoreNow(previous: true)
        #expect(backend.restores.isEmpty)
        if bootID == nil {
            service.setEnabled(true); service.useCurrentLayout(); service.willSleep(); service.didWake()
            #expect(service.status == .captureFailed && !service.busy)
            #expect(backend.captures == 0 && backend.restores.isEmpty)
        }
    }
}
@Test func windowBootIdentityIsAStableKernelUUID() throws {
    let value = try #require(WindowBootSession.currentID())
    #expect(UUID(uuidString: value) != nil)
    #expect(WindowBootSession.currentID() == value)
}

@Test @MainActor func windowLayoutWorkAreaOnlyChangeDoesNotLatchPendingOrBlockNextSleepSave() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 10
    backend.screens[0].visibleFrame.height -= 30
    var fresh = saved; fresh.windows[0].frame.x = 100
    backend.candidate = fresh
    service.displaysChanged()
    #expect(!service.pending && backend.restores.isEmpty)
    service.willSleep()
    #expect(service.current == fresh && service.lastGood == saved && backend.captures == 1)
}
@Test @MainActor func repeatedRestoreFailuresAllowSleepSavesWithoutReplacingTheGoodBackup() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    var previous = saved; previous.windows[0].frame.x = 50
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(previous), forKey: WindowLayoutService.backupKey)
    var failure = WindowRestoreResult(); failure.fail(saved.windows[0], reason: .ambiguousIdentity)
    backend.results = [failure, failure]
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts = WindowLayoutArtifacts(directory: directory)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1),
                                      artifacts: artifacts, now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 10; service.restoreNow(); try await finish(service)
    #expect(service.pending && service.current == saved && service.lastGood == previous)
    #expect(service.report().restoreReport?.failed == 1)
    #expect(service.report().restoreReport?.issues.first?.reason == .ambiguousIdentity)
    var fresh = saved; fresh.date += 60; fresh.windows[0].frame.x = 200; backend.candidate = fresh
    service.willSleep()
    #expect(service.current?.date == fresh.date && service.current?.windows == fresh.windows)
    #expect(service.current?.savedDuringPendingRestore == true && service.lastGood == saved)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == service.current)

    var nextFailure = WindowRestoreResult(); nextFailure.fail(fresh.windows[0], reason: .ambiguousIdentity)
    backend.results = [nextFailure, nextFailure]
    service.didWake(); try await finish(service)
    #expect(service.pending && backend.restores.last == fresh.windows)
    var partial = fresh; partial.date += 60; partial.windows[0].frame.x = 300
    partial.savedWithOmissions = true; backend.candidate = partial
    uptime = 20; service.willSleep()
    #expect(service.current?.windows == partial.windows && service.report().savedWithOmissions == true)
    #expect(service.lastGood == saved && backend.captures == 2)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.backupKey)) == saved)

    service.didWake(); try await finish(service)
    #expect(!service.pending && !defaults.bool(forKey: WindowLayoutService.pendingKey))
    #expect(!defaults.bool(forKey: WindowLayoutService.restoreKey) && service.restoreReport?.failed == 0)
    #expect(backend.restores.last == partial.windows && service.report().savedWithOmissions == true)
    let diagnostics = try #require(service.diagnostics())
    let log = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
    let events = try #require(log["events"] as? [[String: Any]])
    #expect(events.compactMap { $0["action"] as? String } == [
        "manualRestore", "automaticSave", "automaticRestore", "automaticSave", "automaticRestore"
    ])
    #expect(events.compactMap { $0["result"] as? String } == ["incomplete", "saved", "incomplete", "savedWithOmissions", "restored"])
}
@Test @MainActor func retryKeepsFullIdentityScopeAndReportsOnlyFailuresRemainingAfterRetry() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    var saved = layoutFixture(); var second = saved.windows[0]; second.id = UUID(); second.title = "Second"
    saved.windows.append(second)
    let backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var partial = WindowRestoreResult(restored: 1); partial.fail(second, reason: .timeBudget)
    backend.results = [partial, WindowRestoreResult(restored: 1)]
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); try await finish(service)
    #expect(backend.restores == [saved.windows, [second]])
    #expect(backend.identityScopes == [saved.windows, saved.windows])
    #expect(service.restoreReport?.restored == 2 && service.restoreReport?.failed == 0)
    #expect(service.restoreReport?.issues.isEmpty == true && !service.pending)
}
@Test @MainActor func displayChangeDuringRestoreProtectsBothSnapshotsAndExplainsInterruption() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.backupKey)
    backend.onRestore = { backend.screens = [] }
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); try await finish(service)
    #expect(service.status == .incomplete && service.pending)
    #expect(service.current == saved && service.lastGood == saved)
    #expect(service.restoreReport?.interrupted == .displayChanged)
}
