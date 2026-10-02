import LookoutCore
import Testing

@Test func unsupportedEnergyIsRemovedWithoutChangingOtherChoicesOrOrdering() {
    let intel = MonitoringCapabilities(supportsProcessEnergy: false)
    let original = MonitorConfiguration(enabled: [.cpu, .power, .disk], order: [.power, .disk, .cpu],
                                        interval: 5, interface: "en1")
    let filtered = intel.applying(to: original)
    #expect(filtered.enabled == [.cpu, .disk])
    #expect(filtered.order == original.order)
    #expect(filtered.interval == 5 && filtered.interface == "en1")
    #expect(original.enabled.contains(.power))
    #expect(!intel.supports(.power))
    #expect(Metric.allCases.filter { intel.supports($0) }.count == 5)
    #expect(MonitoringCapabilities(supportsProcessEnergy: true).applying(to: original) == original)
    #expect(intel.applying(to: MonitorConfiguration(enabled: [])).enabled.isEmpty)
}

@Test func unsupportedEnergyNeverInvokesTheCollectorEvenWithPreviouslyEnabledSettings() async {
    let sampler = MetricSampler(capabilities: MonitoringCapabilities(supportsProcessEnergy: false))
    let readings = await sampler.collect(MonitorConfiguration(enabled: [.power]))
    #expect(readings.isEmpty)
    #expect(await sampler.invocationCounts()[.power] == nil)
}
