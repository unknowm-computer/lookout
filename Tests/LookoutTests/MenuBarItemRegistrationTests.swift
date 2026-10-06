import LookoutCore
import Foundation
@testable import Lookout
import Testing

@Test @MainActor func splittingMemorySSDGroupPreservesSSDMonitoringAndSavedValues() throws {
    let name = "LookoutTests.splitStorage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    store.setStorageInterval(1800)
    store.setMenuBarValue(.available, for: .ssd)
    store.setMenuBarDensity(.normal)
    store.setMenuBarGrouping(memorySSD: true)
    let before = store.configuration
    store.setMenuBarGrouping(memorySSD: false)
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.configuration.enabled == before.enabled)
    #expect(restored.configuration.enabled.contains(.ssd))
    #expect(restored.configuration.order == before.order)
    #expect(restored.configuration.storageInterval == 1800)
    #expect(restored.menuBarValues.storage == .available)
    let metrics = restored.menuBarDensity.metrics(configuration: restored.configuration, priority: restored.menuBarPriority)
    let units = restored.configuration.menuBarGrouping.units(metrics: metrics)
    #expect(units.contains(.metric(.memory)) && units.contains(.metric(.ssd)))
    #expect(!units.contains(.memorySSD))
}

@Test @MainActor func ungroupedMemoryAndSSDRegisterCompleteIndependentItemsBeforeTheNextItem() {
    let metrics: [Metric] = [.cpu, .memory, .ssd, .gpu]
    let grouping = MenuBarGrouping(cpuGPU: true, memorySSD: false)
    let slots = grouping.units(metrics: metrics)
    var items: [MenuBarUnit: String] = [:]
    var events: [String] = []
    MenuBarItemRegistration.update(slots: slots, items: &items, create: { slot in
        events.append("create \(slot.id)")
        return slot.id
    }, configure: { slot, item in
        events.append("configure \(item)")
        #expect(item == slot.id)
    })
    #expect(events == ["create ssd", "configure ssd", "create memory", "configure memory", "create cpu-gpu", "configure cpu-gpu"])
    #expect(items[.metric(.memory)] != nil && items[.metric(.ssd)] != nil)
    #expect(items.count == 3)
    events.removeAll()
    MenuBarItemRegistration.update(slots: slots, items: &items, create: { slot in
        events.append("unexpected create \(slot.id)")
        return slot.id
    }, configure: { _, item in events.append("configure \(item)") })
    #expect(events == ["configure ssd", "configure memory", "configure cpu-gpu"])
}
