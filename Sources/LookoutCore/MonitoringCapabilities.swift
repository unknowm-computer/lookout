/// Platform availability is applied after loading preferences, without erasing saved choices.
public struct MonitoringCapabilities: Sendable {
    public let supportsProcessEnergy: Bool
    public init(supportsProcessEnergy: Bool) { self.supportsProcessEnergy = supportsProcessEnergy }
    public static var current: Self {
        #if arch(arm64)
        Self(supportsProcessEnergy: true)
        #else
        Self(supportsProcessEnergy: false)
        #endif
    }
    public func supports(_ metric: Metric) -> Bool { metric != .power || supportsProcessEnergy }
    public func applying(to configuration: MonitorConfiguration) -> MonitorConfiguration {
        var result = configuration
        result.enabled = result.enabled.filter { supports($0) }
        return result
    }
}
