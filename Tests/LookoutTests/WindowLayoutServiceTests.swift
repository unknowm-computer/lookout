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
    var results: [WindowRestoreResult] = []
    init(_ value: WindowLayoutSnapshot) { screens = value.displays; candidate = value }
    func displays() -> [LayoutDisplay] { reads += 1; return screens }
    func capture() -> WindowLayoutSnapshot? { captures += 1; return candidate }
    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay]) -> WindowRestoreResult {
        restores.append(windows)
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
    return (name, UserDefaults(suiteName: name)!)
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
@Test @MainActor func windowLayoutFreezesSnapshotWhenDisplayDisconnectPrecedesSleep() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    defaults.set(true, forKey: WindowLayoutService.enabledKey)
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(1), attempts: 5, now: { 20 })
    defer { service.stop() }
    backend.screens = []; service.displaysChanged(); service.willSleep(); service.didWake()
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
@Test @MainActor func windowLayoutRetriesOnlyFailedWindowsAndProtectsIncompleteRestoration() async throws {
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
    service.willSleep(); #expect(backend.captures == 0 && service.current == saved)
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
@Test @MainActor func windowLayoutRejectsPartialCaptureAndPermissionRevocationWithoutOverwriting() async throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(saved)
    var uptime: TimeInterval = 0
    defaults.set(try JSONEncoder().encode(saved), forKey: WindowLayoutService.currentKey)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false,
                                      step: .milliseconds(2), now: { uptime })
    defer { service.stop() }
    service.setEnabled(true); uptime = 10
    backend.candidate = WindowLayoutSnapshot(displays: saved.displays, windows: [])
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
    service.setEnabled(true); uptime = 3; service.displaysChanged(); uptime = 6
    backend.candidate = nil; service.useCurrentLayout()
    #expect(service.pending && service.current == saved && service.lastGood == nil)
    var new = saved; new.displays[0].id = "new"; new.windows[0].displayID = "new"
    backend.screens = new.displays; backend.candidate = new
    service.useCurrentLayout()
    #expect(!service.pending && service.current == new && service.lastGood == saved)
    service.restoreNow(previous: true); service.stop()
    #expect(service.current == new && service.lastGood == saved)
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
    service.setEnabled(true); service.displaysChanged(); service.refresh()
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

@Test @MainActor func helperMigratesLegacySnapshotsOnceAndKeepsAnIndependentBackup() throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), backend = LayoutBackendFixture(layoutFixture())
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, startEnabled: false)
    defer { service.stop() }
    let data = try JSONEncoder().encode(saved)
    service.importLegacy(WindowLayoutTransfer(current: Data("bad".utf8), backup: data, pending: true, restoreRequested: true))
    #expect(service.current == nil && service.lastGood == saved && service.pending)
    #expect(!service.enabled && backend.permissionChecks == 0)
    service.importLegacy(WindowLayoutTransfer(current: data, backup: nil, pending: false, restoreRequested: false))
    #expect(service.current == nil && service.lastGood == saved && service.pending)
}
@Test @MainActor func helperMigrationNeverOverwritesItsNewerSavedLayout() throws {
    let (name, defaults) = layoutDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let saved = layoutFixture(), data = try JSONEncoder().encode(saved)
    defaults.set(data, forKey: WindowLayoutService.currentKey)
    let backend = LayoutBackendFixture(saved)
    let service = WindowLayoutService(defaults: defaults, backend: backend, observe: false, startEnabled: false)
    defer { service.stop() }
    service.importLegacy(WindowLayoutTransfer(current: nil, backup: data, pending: true, restoreRequested: true))
    #expect(service.current == saved && service.lastGood == nil && !service.pending)
    #expect(defaults.data(forKey: WindowLayoutService.currentKey) == data)
}
