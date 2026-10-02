import Foundation

public enum ChartStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, line, bar, gauge
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: "자동"; case .line: "라인"; case .bar: "바"; case .gauge: "게이지" }
    }
    public func resolved(for metric: Metric) -> ChartStyle {
        guard self == .automatic else { return self }
        switch metric {
        case .cpu, .gpu: return .gauge
        case .memory: return .bar
        case .network, .disk, .power: return .line
        }
    }
}

/// Keep raw identifiers so a newer or malformed setting does not discard other preferences.
public struct ChartPreferences: Codable, Equatable, Sendable {
    public var styles: [String: String]
    public init(styles: [String: String] = [:]) { self.styles = styles }
    public func style(for metric: Metric) -> ChartStyle {
        styles[metric.rawValue].flatMap(ChartStyle.init(rawValue:)) ?? .automatic
    }
    public mutating func set(_ style: ChartStyle, for metric: Metric) {
        styles[metric.rawValue] = style == .automatic ? nil : style.rawValue
    }
    public var normalized: ChartPreferences {
        ChartPreferences(styles: styles.filter {
            Metric(rawValue: $0.key) != nil && ChartStyle(rawValue: $0.value) != nil && $0.value != ChartStyle.automatic.rawValue
        })
    }
}

public struct ChartBar: Sendable {
    public let index: Int
    public let primary: Double?
    public let secondary: Double?
}

public struct UsageStatistics: Sendable {
    public let average: Double?
    public let maximum: Double?
}

public enum ChartData {
    /// Weight continuous samples by elapsed time, excluding missing and interrupted periods.
    public static func usageStatistics(history: [HistoryPoint], end: Date) -> UsageStatistics {
        let start = end.addingTimeInterval(-300)
        let points = history.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
        var values: [Double] = [], previous: HistoryPoint?
        var integral = 0.0, duration = 0.0
        for point in points {
            guard let value = point.primary, value.isFinite, (0...100).contains(value) else {
                previous = nil
                continue
            }
            values.append(value)
            if let previous, previous.segment == point.segment, let priorValue = previous.primary {
                let elapsed = point.date.timeIntervalSince(previous.date)
                if elapsed > 0 {
                    integral += (priorValue + value) / 2 * elapsed
                    duration += elapsed
                }
            }
            previous = point
        }
        let average: Double? = duration > 0 ? integral / duration :
            (values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
        return UsageStatistics(average: average, maximum: values.max())
    }
    public static func rateUpperBound(history: [HistoryPoint], current: ReadingValue? = nil) -> Double {
        var maximum = 1000.0
        for point in history {
            for value in [point.primary, point.secondary].compactMap({ $0 }) where value.isFinite {
                maximum = max(maximum, value)
            }
        }
        if let current {
            for rate in [current.primary, current.secondary].compactMap({ $0 }) where rate.isFinite { maximum = max(maximum, rate) }
        }
        let magnitude = pow(10, floor(log10(maximum)))
        return ceil(maximum / magnitude) * magnitude
    }
    public static func energyUpperBound(history: [HistoryPoint], current: Double? = nil) -> Double {
        let values = history.compactMap(\.primary) + (current.map { [$0] } ?? [])
        let maximum = values.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        let bound = max(1, maximum)
        let magnitude = pow(10, floor(log10(bound)))
        return ceil(bound / magnitude) * magnitude
    }
    /// Fixed time bins; a missing sample or continuity change leaves a visible gap.
    public static func bars(history: [HistoryPoint], end: Date, count: Int = 60) -> [ChartBar] {
        guard count > 0 else { return [] }
        let start = end.addingTimeInterval(-300), duration = 300 / Double(count)
        let points = history.filter { $0.date >= start && $0.date <= end }
        let groups = Dictionary(grouping: points) { min(count - 1, Int($0.date.timeIntervalSince(start) / duration)) }
        return (0..<count).map { index in
            guard let group = groups[index], Set(group.map(\.segment)).count == 1,
                  group.allSatisfy({ $0.primary?.isFinite == true }) else {
                return ChartBar(index: index, primary: nil, secondary: nil)
            }
            let primary = group.compactMap(\.primary)
            let secondary = group.compactMap(\.secondary)
            return ChartBar(index: index, primary: primary.reduce(0, +) / Double(primary.count),
                            secondary: secondary.count == group.count && secondary.allSatisfy(\.isFinite)
                                ? secondary.reduce(0, +) / Double(secondary.count) : nil)
        }
    }
}
