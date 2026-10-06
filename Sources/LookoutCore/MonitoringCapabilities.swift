/// Platform availability is applied after loading preferences, without erasing saved choices.
public struct MonitoringCapabilities: Sendable {
    public let supportsGPU: Bool
    public let supportsProcessEnergy: Bool
    public init(supportsGPU: Bool, supportsProcessEnergy: Bool) {
        self.supportsGPU = supportsGPU
        self.supportsProcessEnergy = supportsProcessEnergy
    }
    public static var current: Self {
        #if arch(arm64)
        Self(supportsGPU: true, supportsProcessEnergy: true)
        #else
        Self(supportsGPU: false, supportsProcessEnergy: false)
        #endif
    }
    public func supports(_ metric: Metric) -> Bool {
        switch metric {
        case .gpu: supportsGPU
        case .power: supportsProcessEnergy
        default: true
        }
    }
    public func unsupportedReason(for metric: Metric) -> String? {
        supports(metric) ? nil : "Intel Mac에서는 \(metric.title) 모니터링을 지원하지 않습니다."
    }
    public func applying(to configuration: MonitorConfiguration) -> MonitorConfiguration {
        var result = configuration
        result.enabled = result.enabled.filter { supports($0) }
        return result
    }
}
