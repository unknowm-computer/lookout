import Foundation
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func refreshIntervalDefaultsToThreeAndPreservesSavedChoices() throws {
    let name = "LookoutTests.refreshInterval.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(MonitorConfiguration().interval == 3)
    #expect(SettingsStore(defaults: defaults).configuration.interval == 3)
    for interval in [1, 2, 3, 5] {
        let store = SettingsStore(defaults: defaults)
        store.setInterval(interval)
        #expect(SettingsStore(defaults: defaults).configuration.interval == interval)
    }
    #expect(MonitorConfiguration(interval: 99).interval == 3)
    let store = SettingsStore(defaults: defaults)
    store.setInterval(99)
    #expect(SettingsStore(defaults: defaults).configuration.interval == 3)
    defaults.set(Data(#"{"version":2}"#.utf8), forKey: SettingsStore.key)
    #expect(SettingsStore(defaults: defaults).configuration.interval == 3)
}
