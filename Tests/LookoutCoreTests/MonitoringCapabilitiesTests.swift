import LookoutCore
import Testing

@Test func unsupportedGPUAndEnergyAreRemovedWithoutChangingOtherChoicesOrOrdering() {
    let intel = MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false)
    let original = MonitorConfiguration(enabled: [.cpu, .gpu, .power, .disk], order: [.power, .gpu, .disk, .cpu],
                                        interval: 5, interface: "en1")
    let filtered = intel.applying(to: original)
    #expect(filtered.enabled == [.cpu, .disk])
    #expect(filtered.order == original.order)
    #expect(filtered.interval == 5 && filtered.interface == "en1")
    #expect(original.enabled.contains(.power))
    #expect(original.enabled.contains(.gpu))
    #expect(!intel.supports(.power) && !intel.supports(.gpu))
    #expect(Metric.allCases.filter { intel.supports($0) } == [.cpu, .memory, .ssd, .network, .disk])
    #expect(MonitoringCapabilities(supportsGPU: true, supportsProcessEnergy: true).applying(to: original) == original)
    #expect(intel.applying(to: MonitorConfiguration(enabled: [])).enabled.isEmpty)
}

@Test func unsupportedGPUAndEnergyNeverInvokeCollectorsEvenWithPreviouslyEnabledSettings() async {
    let sampler = MetricSampler(capabilities: MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false))
    let readings = await sampler.collect(MonitorConfiguration(enabled: [.gpu, .power]))
    #expect(readings.isEmpty)
    #expect(await sampler.invocationCounts()[.power] == nil)
    #expect(await sampler.invocationCounts()[.gpu] == nil)
}

@Test func platformCapabilityDefaultsAndReasonsMatchTheRunningArchitecture() {
    #if arch(arm64)
    #expect(MonitoringCapabilities.current.supports(.gpu))
    #expect(MonitoringCapabilities.current.supports(.power))
    #else
    #expect(!MonitoringCapabilities.current.supports(.gpu))
    #expect(!MonitoringCapabilities.current.supports(.power))
    #endif
    let intel = MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false)
    #expect(intel.unsupportedReason(for: .gpu) == L10n.text("Intel Mac에서는 \(Metric.gpu.title) 모니터링을 지원하지 않습니다."))
    #expect(intel.unsupportedReason(for: .power) == L10n.text("Intel Mac에서는 \(Metric.power.title) 모니터링을 지원하지 않습니다."))
    #expect(intel.unsupportedReason(for: .cpu) == nil)
}
