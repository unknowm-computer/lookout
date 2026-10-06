import Foundation
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func intelFiltersSavedGPUAndEnergyButPreservesPreferencesUntilEdited() throws {
    let name = "LookoutTests.intelCapabilities.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let apple = MonitoringCapabilities(supportsGPU: true, supportsProcessEnergy: true)
    let original = SettingsStore(defaults: defaults, capabilities: apple)
    original.setEnabled(.gpu, true)
    original.setEnabled(.power, true)
    original.setMenuBarGrouping(MenuBarGrouping(pairs: [MenuBarPair(.cpu, .gpu), MenuBarPair(.memory, .power)]))
    original.updateAlert(.gpu) { $0.enabled = true }
    let saved = try #require(defaults.data(forKey: SettingsStore.key))
    let intel = SettingsStore(defaults: defaults,
        capabilities: MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false))
    #expect(intel.configuration.enabled == [.cpu, .memory, .ssd, .network, .disk])
    #expect(intel.configuration.order == original.configuration.order)
    #expect(intel.configuration.menuBarGrouping == original.configuration.menuBarGrouping)
    #expect(defaults.data(forKey: SettingsStore.key) == saved)
    #expect(intel.alerts == original.alerts)
    let restored = SettingsStore(defaults: defaults, capabilities: apple)
    #expect(restored.configuration.enabled.contains(.gpu) && restored.configuration.enabled.contains(.power))
    intel.setEnabled(.gpu, true)
    intel.setEnabled(.power, true)
    #expect(!intel.configuration.enabled.contains(.gpu) && !intel.configuration.enabled.contains(.power))
    intel.updateAlert(.gpu) { $0.enabled = false }
    #expect(intel.alerts == original.alerts)
    #expect(intel.configuration.menuBarGrouping.units(metrics: intel.configuration.visible)
        .flatMap(\.metrics) == [.cpu, .memory, .ssd, .network, .disk])
}

@Test @MainActor func intelExcludesRestoredGPUAlertsAndNewGPUSamplesFromEvaluation() throws {
    let capabilities = MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false)
    let monitored = capabilities.applying(to: MonitorConfiguration()).enabled
    let rule = AlertRule(metric: .gpu, enabled: true, threshold: 90, duration: 0)
    let configuration = AlertConfiguration(rules: [rule])
    let reading = MetricReading(metric: .gpu, date: Date(),
        value: .gpu(GPUReading(name: "GPU", utilization: 99, renderer: nil, tiler: nil, sharedMemory: nil)))
    var previous = AlertEngine()
    let event = try #require(previous.evaluate([reading], configuration: configuration,
        monitored: [.gpu], uptime: 8, interval: 2).first)
    var engine = AlertEngine(restored: [event])
    engine.configure(configuration, monitored: monitored)
    #expect(engine.active.isEmpty && engine.notificationEligibleIDs.isEmpty)
    #expect(engine.evaluate([reading], configuration: configuration, monitored: monitored, uptime: 10, interval: 2).isEmpty)
    #expect(engine.active.isEmpty && engine.notificationEligibleIDs.isEmpty)
}
