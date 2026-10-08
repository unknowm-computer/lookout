import Foundation
@testable import Lookout
import LookoutCore
import Testing

@Test @MainActor func rateBasisPersistsIndependentlyWithoutChangingChartOrMonitoringChoices() throws {
    let name = "LookoutTests.rateBasis.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let original = store.configuration, charts = store.charts, alerts = store.alerts
    store.setRateBasis(.count, for: .network)
    store.setRateBasis(.count, for: .disk)
    store.setRateBasis(.count, for: .cpu)
    let restored = SettingsStore(defaults: defaults)
    #expect(restored.configuration.networkRateBasis == .count && restored.configuration.diskRateBasis == .count)
    #expect(restored.configuration.enabled == original.enabled && restored.configuration.order == original.order)
    #expect(restored.configuration.interval == original.interval && restored.configuration.interface == original.interface)
    #expect(restored.charts == charts && restored.alerts == alerts)
    restored.setRateBasis(.data, for: .network)
    #expect(SettingsStore(defaults: defaults).configuration.networkRateBasis == .data)
    #expect(SettingsStore(defaults: defaults).configuration.diskRateBasis == .count)
}

@Test @MainActor func rateRendererKeepsWidthWhenUnitsChangeOrSamplesAreMissing() {
    for metric in [Metric.network, .disk] {
        let empty = MenuBarRenderer.image(metrics: [metric], readings: [:])
        for basis in ActivityRateBasis.allCases {
            let value: ReadingValue = metric == .network ? .network(NetworkReading(interface: "en0", download: 1200, upload: 99, basis: basis)) :
                .disk(DiskReading(capacity: nil, activity: DiskActivityReading(read: 1200, write: 99, basis: basis)))
            let image = MenuBarRenderer.image(metrics: [metric], readings: [metric: MetricReading(metric: metric, date: Date(), value: value)])
            #expect(image.size == empty.size && image.isTemplate)
        }
    }
}
