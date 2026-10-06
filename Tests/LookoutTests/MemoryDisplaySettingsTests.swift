import Foundation
@testable import Lookout
import Testing

@Test @MainActor func swapDetailsDefaultToCompactAndPersistWithoutChangingMonitoring() throws {
    let name = "LookoutTests.swapDisplay.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let configuration = store.configuration, alerts = store.alerts, charts = store.charts
    #expect(!store.showsSwapDetails)
    store.setShowsSwapDetails(true)
    #expect(store.showsSwapDetails)
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.showsSwapDetails)
    #expect(restored.configuration == configuration && restored.alerts == alerts && restored.charts == charts)
    restored.setShowsSwapDetails(false)
    #expect(!SettingsStore(defaults: defaults).showsSwapDetails)
    #expect(defaults.data(forKey: SettingsStore.key) == nil)
    #expect(defaults.data(forKey: "alertSettings.v1") == nil)
    #expect(defaults.data(forKey: "chartSettings.v1") == nil)
}
