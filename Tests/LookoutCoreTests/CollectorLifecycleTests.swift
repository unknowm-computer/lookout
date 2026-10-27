import Foundation
@testable import LookoutCore
import Testing

private final class CoolingLifecycleCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var resets = 0
    func sampled() { lock.lock(); defer { lock.unlock() }; samples += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; resets += 1 }
    var values: (samples: Int, resets: Int) {
        lock.lock(); defer { lock.unlock() }; return (samples, resets)
    }
}

private final class LifecycleCoolingCollector: CoolingSampling {
    let counts: CoolingLifecycleCounts
    init(counts: CoolingLifecycleCounts) { self.counts = counts }
    func reset() { counts.reset() }
    func sample(uptime: Double, force: Bool) throws -> CoolingReading {
        counts.sampled()
        return CoolingReading(cpu: 88, gpu: 70, fans: [], band: .hot, uptime: uptime, canControl: false)
    }
}

@Test func disablingEnergyDoesNotResetTheActiveTemperatureCollector() async throws {
    let counts = CoolingLifecycleCounts()
    let sampler = MetricSampler(
        capabilities: MonitoringCapabilities(supportsGPU: false, supportsProcessEnergy: false, supportsCooling: true),
        coolingCollector: LifecycleCoolingCollector(counts: counts))
    let temperatureOnly = MonitorConfiguration(enabled: [.cooling], interval: 1)
    for _ in 0..<3 {
        let readings = await sampler.collect(temperatureOnly)
        let reading = try #require(readings.first)
        #expect(reading.metric == .cooling && reading.value?.primary == 88)
    }
    // No reset means the real collector can retain its five-second cache and band hysteresis.
    #expect(counts.values.samples == 3 && counts.values.resets == 0)
    let disabled = await sampler.collect(MonitorConfiguration(enabled: []))
    #expect(disabled.isEmpty && counts.values.samples == 3 && counts.values.resets == 1)
    _ = await sampler.collect(temperatureOnly)
    #expect(counts.values.samples == 4 && counts.values.resets == 1)
    await sampler.reset()
    #expect(counts.values.resets == 2)
}
