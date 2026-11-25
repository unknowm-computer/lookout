import AppKit
import Foundation
import LookoutCore
import WindowHelperProtocol
@testable import WindowLayoutRuntime
import Testing

@MainActor private final class LayoutBackendFixture: WindowLayoutBackend {
    var permission = true
    var captureDisplaysAwake = false
    var isScreenLocked = false
    var areScreensAsleep = false
    var permissionChecks = 0
    var isTrusted: Bool { permissionChecks += 1; return permission }
    var screens: [LayoutDisplay]
    var candidate: WindowLayoutSnapshot?
    var captures = 0
    var reads = 0
    var restores: [[LayoutWindow]] = []
    var identityScopes: [[LayoutWindow]] = []
    var results: [WindowRestoreResult] = []
    var onCapture: (() -> Void)?
    var onRestore: (() -> Void)?
    init(_ value: WindowLayoutSnapshot) { screens = value.displays; candidate = value }
    func displays() -> [LayoutDisplay] { reads += 1; return screens }
    func capture(timeBudget: TimeInterval) -> WindowLayoutSnapshot? {
        captures += 1
        onCapture?()
        return candidate
    }
    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay], identityScope: [LayoutWindow]) -> WindowRestoreResult {
        restores.append(windows)
        identityScopes.append(identityScope)
        onRestore?()
        return results.isEmpty ? WindowRestoreResult(restored: windows.count) : results.removeFirst()
    }
}
private func layoutFixture() -> WindowLayoutSnapshot {
    let frame = LayoutRect(x: 0, y: 0, width: 1440, height: 900)
    var layout = WindowLayoutSnapshot(displays: [LayoutDisplay(id: "screen", frame: frame, visibleFrame: frame)],
        windows: [LayoutWindow(bundleID: "fixture", pid: 123, launchDate: Date(), identifier: "one", title: "Window",
                               displayID: "screen", frame: LayoutRect(x: 10, y: 30, width: 500, height: 400))])
    layout.manuallySaved = true
    return layout
}

private enum LayoutPauseEvent: String, CaseIterable {
    case systemSleep, screenSleep, screenLock

    @MainActor func pause(_ service: WindowLayoutService) {
        switch self {
        case .systemSleep: service.willSleep()
        case .screenSleep: service.screensDidSleep()
        case .screenLock: service.screenDidLock()
        }
    }

    @MainActor func resume(_ service: WindowLayoutService) {
        switch self {
        case .systemSleep: service.didWake()
        case .screenSleep: service.screensDidWake()
        case .screenLock: service.screenDidUnlock()
        }
    }
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
    service.refresh()
    for event in LayoutPauseEvent.allCases { event.pause(service); event.resume(service) }
    service.displaysChanged(); service.restoreNow()
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
@Test @MainActor func firstMemoryLayoutRestoresWithoutAnyDiskSaveOrDuplicateWake() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let first = layoutFixture(), backend = LayoutBackendFixture(first)
    backend.captureDisplaysAwake = true
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 3
    try await awaitMemoryLayout(first.date, on: service)
    let captures = backend.captures
    service.willSleep(); service.willSleep()
    #expect(service.pending && backend.captures == captures && backend.restores.isEmpty)
    service.didWake(); try await finish(service)
    service.didWake(); try await finish(service)
    #expect(backend.restores == [first.windows] && !service.pending)
    #expect(service.status == .restored(1, 0))
    #expect(service.current == nil && service.lastGood == nil && service.report().savedAt == nil)
    #expect(defaults.object(forKey: WindowLayoutService.currentKey) == nil)
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
    #expect(service.current == saved && !service.pending && backend.captures == 0 && backend.restores.isEmpty)
    #expect(service.status == .displayNotReady)
    backend.screens = saved.displays
    service.displaysChanged(); service.refresh(); try await finish(service)
    #expect(service.status == .displayNotReady && backend.restores.isEmpty)
    service.restoreNow(); try await finish(service)
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
    #expect(backend.restores.isEmpty && backend.captures == 0)
    service.restoreNow(); try await finish(service)
    #expect(backend.restores == [backup.windows])
}
@Test @MainActor func windowLayoutWakeRetriesOnlyFailedWindowsAndEndsUntilManualRestore() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    var saved = layoutFixture(); var second = saved.windows[0]; second.id = UUID(); second.identifier = "two"
    saved.windows.append(second)
    let backend = LayoutBackendFixture(saved)
    backend.candidate = nil
    backend.results = [WindowRestoreResult(restored: 1, failed: [second]), WindowRestoreResult(failed: [second])]
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true); service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == [saved.windows, [second]])
    #expect(!service.pending && service.status == .incomplete && service.restoreReport?.failed == 1)
    #expect(service.current == saved && service.canRestore)

    backend.screens[0].frame.x += 80
    service.displaysChanged(); service.refresh(); service.didWake()
    try await finish(service)
    #expect(backend.restores == [saved.windows, [second]])
    #expect(!service.pending && service.status == .incomplete && service.restoreReport?.failed == 1)

    service.restoreNow(); try await finish(service)
    #expect(backend.restores == [saved.windows, [second], saved.windows])
    #expect(!service.pending && service.status == .restored(2, 0))
}
@Test @MainActor func windowLayoutDisableCancelsRestoreUntilTheNextExplicitRequest() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(2))
    defer { service.stop() }
    service.setEnabled(true); service.restoreNow(); service.setEnabled(false)
    try await Task.sleep(for: .milliseconds(15))
    #expect(!service.busy && service.status == .disabled && !service.pending && backend.restores.isEmpty)
    #expect(!defaults.bool(forKey: WindowLayoutService.backupProtectionKey))
    service.didWake(); service.setEnabled(true); try await finish(service)
    #expect(backend.restores.isEmpty)
    service.restoreNow(); try await finish(service)
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
    #expect(service.current == saved && service.lastGood == nil && backend.captures == 0)
    service.didWake(); backend.permission = false; try await finish(service)
    #expect(service.status == .permission && !service.pending && backend.restores.isEmpty)
    backend.permission = true
    service.refresh(); try await finish(service)
    #expect(backend.restores.isEmpty && service.canRestore)
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
    #expect(!service.pending && service.status == .captureFailed && service.current == saved && service.lastGood == nil)
    #expect(!defaults.bool(forKey: WindowLayoutService.backupProtectionKey))
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
    var unmarkedCapture = fresh
    unmarkedCapture.manuallySaved = nil
    let backend = LayoutBackendFixture(unmarkedCapture)
    // The Dock work area can change while the user is confirming the save.
    backend.screens[0].visibleFrame.height -= 30
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }

    service.restoreNow()
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
@Test @MainActor func windowLayoutClosedWindowsAreSkippedAndEndTheRestore() async throws {
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
    #expect(!service.pending && !service.busy && backend.restores.isEmpty)
    #expect(!defaults.bool(forKey: WindowLayoutService.restoreKey))
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == [saved.windows] && !service.pending)
}

@Test @MainActor func workspaceEventsPauseOnDisplayAndSystemSleepAndRestoreOnWake() async throws {
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
    center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    #expect(service.pending && backend.captures == 0 && backend.restores.isEmpty)
    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    try await finish(service)
    #expect(backend.restores == [saved.windows])
    uptime = 15
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(service.pending && backend.captures == 0)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await finish(service)
    #expect(!service.pending && backend.restores == [saved.windows, saved.windows])
    service.stop()
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(!service.pending && backend.captures == 0)
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
    defaults.set(true, forKey: WindowLayoutService.backupProtectionKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), bootSessionID: "current-boot", now: { uptime })
    defer { service.stop() }
    #expect(service.current == nil && service.lastGood == nil && !service.pending)
    #expect(defaults.data(forKey: WindowLayoutService.currentKey) == nil)
    #expect(defaults.data(forKey: WindowLayoutService.backupKey) == nil)
    #expect(!defaults.bool(forKey: WindowLayoutService.pendingKey) && !defaults.bool(forKey: WindowLayoutService.restoreKey))
    #expect(!defaults.bool(forKey: WindowLayoutService.backupProtectionKey))
    #expect(defaults.string(forKey: WindowLayoutService.bootSessionKey) == "current-boot")
    #expect(service.enabled && backend.restores.isEmpty)
    uptime = 3; service.useCurrentLayout()
    #expect(service.current == fresh && service.lastGood == nil && backend.captures == 1)
    #expect(backend.restores.isEmpty && !service.pending)
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == [fresh.windows])
}
@Test @MainActor func windowLayoutSameBootRelaunchKeepsLayoutsWithoutReplayingLegacyRequest() async throws {
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
    #expect(!defaults.bool(forKey: WindowLayoutService.pendingKey) && !defaults.bool(forKey: WindowLayoutService.restoreKey))
    #expect(!defaults.bool(forKey: WindowLayoutService.backupProtectionKey))
    service.refresh(); try await finish(service)
    #expect(backend.restores.isEmpty)
    service.restoreNow(); try await finish(service)
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

@Test @MainActor func windowLayoutWorkAreaOnlyChangeKeepsManualLayoutForWake() async throws {
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
    #expect(service.current == saved && service.lastGood == nil && backend.captures == 0)
}
@Test @MainActor func repeatedRestoreFailuresPreserveBothDiskSlotsAcrossSleep() async throws {
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
    #expect(!service.pending && service.current == saved && service.lastGood == previous)
    #expect(service.report().restoreReport?.failed == 1)
    #expect(service.report().restoreReport?.issues.first?.reason == .ambiguousIdentity)
    backend.results = [failure, failure]
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(service.current == saved && service.lastGood == previous && backend.captures == 0)
    #expect(backend.restores.allSatisfy { $0 == saved.windows })
    let diagnostics = try #require(service.diagnostics())
    let log = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
    let events = try #require(log["events"] as? [[String: Any]])
    #expect(events.compactMap { $0["action"] as? String } == ["manualRestore", "automaticRestore"])
    #expect(events.compactMap { $0["result"] as? String } == ["incomplete", "incomplete"])
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
    #expect(service.status == .incomplete && !service.pending)
    #expect(service.current == saved && service.lastGood == saved)
    #expect(service.restoreReport?.interrupted == .displayChanged)
}

@MainActor private func awaitCaptures(_ count: Int, on backend: LayoutBackendFixture) async throws {
    for _ in 0..<150 where backend.captures < count { try await Task.sleep(for: .milliseconds(2)) }
    #expect(backend.captures >= count)
}

@MainActor private func awaitMemoryLayout(_ date: Date, on service: WindowLayoutService) async throws {
    for _ in 0..<150 where service.report().lastRecentCaptureAt != date {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(service.report().lastRecentCaptureAt == date)
}

@Test(arguments: LayoutPauseEvent.allCases)
@MainActor private func disconnectBeforePauseUsesTheRecentCompleteArrangement(_ event: LayoutPauseEvent) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    var saved = layoutFixture()
    var external = saved.displays[0]
    external.id = "external"
    external.frame.x = 1440
    external.visibleFrame = external.frame
    saved.displays.append(external)

    var recent = saved
    recent.date += 15
    recent.windows[0].displayID = external.id
    recent.windows[0].frame.x = 130
    let backend = LayoutBackendFixture(saved)
    backend.captureDisplaysAwake = true
    backend.candidate = recent
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1),
                                      recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 5
    #expect(service.report().lastRecentCaptureAt == nil)
    try await awaitMemoryLayout(recent.date, on: service)
    #expect(service.report().lastRecentCaptureAt == recent.date && service.report().savedAt == saved.date)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == saved)
    #expect(service.current == saved && service.lastGood == nil)

    var incomplete = recent
    incomplete.date += 15; incomplete.windows[0].frame.x = 240; incomplete.savedWithOmissions = true
    backend.candidate = incomplete
    try await awaitCaptures(backend.captures + 1, on: backend)
    #expect(service.report().lastRecentCaptureAt == recent.date)
    backend.candidate = nil
    try await awaitCaptures(backend.captures + 1, on: backend)
    #expect(service.report().lastRecentCaptureAt == recent.date)

    backend.screens.removeLast()
    backend.captureDisplaysAwake = false
    service.displaysChanged()
    uptime += 5 // Exercise the missing-display check after the configuration has settled.
    let captures = backend.captures
    event.pause(service)
    #expect(backend.captures == captures)
    #expect(service.current == saved && service.lastGood == nil)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == saved)

    backend.screens = recent.displays
    backend.captureDisplaysAwake = true
    event.resume(service); try await finish(service)
    #expect(backend.restores == [recent.windows])
    #expect(service.report().lastRecentCaptureAt == recent.date)
    service.setEnabled(false)
    #expect(service.report().lastRecentCaptureAt == nil)
}

@Test(arguments: LayoutPauseEvent.allCases)
@MainActor private func incompleteWindowAtPauseCannotReplaceLastCompleteMemoryLayout(_ event: LayoutPauseEvent) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture()
    let backend = LayoutBackendFixture(saved)
    backend.captureDisplaysAwake = true
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    var recent = saved; recent.date += 15; recent.windows[0].frame.x = 130
    backend.candidate = recent
    service.setEnabled(true); uptime = 5
    try await awaitMemoryLayout(recent.date, on: service)
    service.setCaptureInterval(.oneMinute)
    let captures = backend.captures
    try await Task.sleep(for: .milliseconds(25))
    #expect(backend.captures == captures)
    var partial = recent; partial.date += 5; partial.windows[0].frame.x = 160; partial.savedWithOmissions = true
    backend.candidate = partial
    event.pause(service)
    #expect(service.current == saved && service.lastGood == nil)
    #expect(service.report().lastRecentCaptureAt == recent.date && service.report().savedAt == saved.date)
    #expect(backend.captures == captures && backend.restores.isEmpty)
    event.resume(service); try await finish(service)
    #expect(backend.restores == [recent.windows])
}

@Test @MainActor func displayReconnectCannotReplaceTheRecentArrangementBeforeSleep() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture()
    let backend = LayoutBackendFixture(saved)
    backend.captureDisplaysAwake = true
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    var recent = saved; recent.date += 15; recent.windows[0].frame.x = 130
    backend.candidate = recent
    service.setEnabled(true); uptime = 5
    try await awaitMemoryLayout(recent.date, on: service)
    backend.screens = []
    service.displaysChanged()
    backend.screens = saved.displays
    service.displaysChanged()
    uptime = 10
    var displaced = recent; displaced.date += 15; displaced.windows[0].frame.x = 220
    backend.candidate = displaced
    let captures = backend.captures
    try await Task.sleep(for: .milliseconds(25))
    #expect(backend.captures == captures)

    backend.candidate = nil
    service.willSleep()
    #expect(service.current == saved)
    service.didWake(); try await finish(service)
    #expect(backend.restores == [recent.windows])
}

@Test(arguments: LayoutPauseEvent.allCases, [true, false])
@MainActor private func overlappingPausesDoNotSaveAndRestoreOnlyOnce(first: LayoutPauseEvent, systemWakesFirst: Bool) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts = WindowLayoutArtifacts(directory: directory)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), artifacts: artifacts, now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 5
    backend.isScreenLocked = true
    backend.areScreensAsleep = true
    var fresh = saved; fresh.date += 3; fresh.windows[0].frame.x = 160
    backend.candidate = fresh
    first.pause(service)
    backend.candidate = saved // A later notification must not replace the selected layout or rotate its backup.
    service.screenDidLock()
    service.screensDidSleep()
    service.willSleep()
    if systemWakesFirst { service.didWake() }
    backend.areScreensAsleep = false
    service.screensDidWake()
    if !systemWakesFirst { service.didWake() }
    #expect(backend.captures == 0)
    #expect(!service.busy && backend.restores.isEmpty)

    backend.isScreenLocked = false
    service.screenDidUnlock()
    try await finish(service)
    #expect(service.current == saved && service.lastGood == nil)
    #expect(backend.restores == [saved.windows])
    service.screenDidUnlock(); service.screensDidWake(); service.didWake()
    try await finish(service)
    #expect(backend.restores == [saved.windows] && !service.pending)
    let diagnostics = try #require(service.diagnostics())
    let log = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
    let events = try #require(log["events"] as? [[String: Any]])
    let saves = events.filter { $0["action"] as? String == "automaticSave" }
    #expect(saves.isEmpty)
    let restored = try #require(events.last)
    #expect(restored["action"] as? String == "automaticRestore")
    #expect(restored["trigger"] as? String == "systemWake")
}

@Test(arguments: LayoutPauseEvent.allCases, [true, false])
@MainActor private func wakeRestoresRecentOrFallsBackToTheManualLayout(_ event: LayoutPauseEvent, hasRecent: Bool) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    backend.captureDisplaysAwake = hasRecent
    var recent = saved; recent.date += 15; recent.windows[0].frame.x = 130
    backend.candidate = recent
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 5
    if hasRecent { try await awaitMemoryLayout(recent.date, on: service) }
    backend.candidate = nil
    let beforePause = backend.captures
    event.pause(service)
    let captures = backend.captures
    let expected = hasRecent ? recent : saved
    #expect(captures == beforePause && service.current == saved)
    #expect(WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.currentKey)) == saved)
    #expect(service.lastGood == nil)
    try await Task.sleep(for: .milliseconds(25))
    #expect(backend.captures == captures && backend.restores.isEmpty)
    event.resume(service)
    try await finish(service)
    #expect(service.current == saved && backend.restores == [expected.windows])
    #expect(backend.captures == captures)
}

@Test @MainActor func systemWakeWaitsForAnAsleepDisplayEvenWithoutItsSleepNotification() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 5
    service.willSleep()
    backend.areScreensAsleep = true
    service.didWake()
    #expect(!service.busy && backend.restores.isEmpty)
    backend.areScreensAsleep = false
    service.screensDidWake()
    try await finish(service)
    #expect(backend.restores == [saved.windows] && !service.pending)
}

@Test(arguments: [false, true])
@MainActor func wakeAfterUpgradeOnlyUsesAnIdentifiableManualSave(hasManualRecord: Bool) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = WindowLayoutArtifacts(directory: directory)
    var older = layoutFixture(); older.manuallySaved = nil
    var partial = older; partial.date += 600; partial.savedWithOmissions = true
    partial.windows[0].frame.x += 250
    defaults.set(try JSONEncoder().encode(older), forKey: WindowLayoutService.backupKey)
    defaults.set(try JSONEncoder().encode(partial), forKey: WindowLayoutService.currentKey)
    if hasManualRecord { journal.record(WindowLayoutLogEvent("manualSave", "saved", layout: older)) }
    journal.record(WindowLayoutLogEvent("automaticSave", "savedWithOmissions", layout: partial))
    let backend = LayoutBackendFixture(partial)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
        step: .milliseconds(1), artifacts: WindowLayoutArtifacts(directory: directory))
    defer { service.stop() }
    service.setEnabled(true)
    service.willSleep(); service.didWake(); try await finish(service)
    #expect(backend.restores == (hasManualRecord ? [older.windows] : []))
    #expect(service.current == partial && backend.captures == 0)
    let persisted = WindowLayoutSnapshot.decode(defaults.data(forKey: WindowLayoutService.backupKey))
    #expect((persisted?.manuallySaved == true) == hasManualRecord)
}

@Test(arguments: LayoutPauseEvent.allCases)
@MainActor private func pauseDuringManualSaveKeepsThePreviousManualLayout(_ event: LayoutPauseEvent) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture()
    let persisted = try JSONEncoder().encode(saved)
    defaults.set(persisted, forKey: WindowLayoutService.currentKey)
    var interrupted = saved; interrupted.date += 1; interrupted.windows[0].frame.x += 200
    let backend = LayoutBackendFixture(interrupted)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, step: .milliseconds(1))
    defer { service.stop() }
    service.setEnabled(true)
    backend.onCapture = { event.pause(service) }
    service.useCurrentLayout()
    #expect(defaults.data(forKey: WindowLayoutService.currentKey) == persisted && service.lastGood == nil)
    event.resume(service); try await finish(service)
    #expect(backend.restores == [saved.windows])
}

@Test(arguments: LayoutPauseEvent.allCases)
@MainActor private func pauseDuringPeriodicCaptureDiscardsOnlyTheInFlightSample(_ event: LayoutPauseEvent) async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let original = layoutFixture()
    let backend = LayoutBackendFixture(original)
    backend.captureDisplaysAwake = true
    var uptime: TimeInterval = 0
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
        step: .milliseconds(1), recentCaptureInterval: .milliseconds(5), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 5
    try await awaitMemoryLayout(original.date, on: service)
    var disrupted = original; disrupted.date += 1; disrupted.windows[0].frame.x += 200
    backend.candidate = disrupted
    backend.onCapture = { event.pause(service) }
    try await awaitCaptures(backend.captures + 1, on: backend)
    event.resume(service); try await finish(service)
    #expect(backend.restores == [original.windows] && service.report().lastRecentCaptureAt == original.date)
    #expect(service.snapshot == nil)
}
