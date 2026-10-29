import FanSupport

/// The sampler owns this collector's lifetime independently of other metrics.
protocol CoolingSampling {
    func reset()
    func sample(uptime: Double, force: Bool) throws -> CoolingReading
}

extension CoolingCollector: CoolingSampling {}
