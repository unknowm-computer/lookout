import Foundation

/// Data throughput and operation frequency use distinct counters, never an estimated conversion.
public enum ActivityRateBasis: String, CaseIterable, Codable, Sendable, Identifiable {
    case data, count
    public var id: String { rawValue }
    public func title(for metric: Metric) -> String {
        self == .data ? L10n.text("데이터") : metric == .network ? L10n.text("패킷") : "IO"
    }
    public func format(_ value: Double, for metric: Metric) -> String {
        guard self == .count else { return ValueFormat.rate(value) }
        let value = max(0, value)
        let divisor = value >= 1e6 ? 1e6 : value >= 1000 ? 1000.0 : 1
        let suffix = divisor == 1e6 ? "M" : divisor == 1000 ? "k" : ""
        let number = String(format: divisor == 1 ? "%.0f" : "%.1f", value / divisor)
        return "\(number)\(suffix) \(metric == .network ? "pkt/s" : "IO/s")"
    }
}

extension MonitorConfiguration {
    public func rateBasis(for metric: Metric) -> ActivityRateBasis {
        metric == .network ? networkRateBasis : metric == .disk ? diskRateBasis : .data
    }
}
