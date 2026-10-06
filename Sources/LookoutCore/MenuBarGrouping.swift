import Foundation

public enum StoragePollingInterval: Int, CaseIterable, Sendable, Identifiable {
    case thirtySeconds = 30, oneMinute = 60, fiveMinutes = 300, tenMinutes = 600, thirtyMinutes = 1800
    public var id: Int { rawValue }
    public var title: String { rawValue < 60 ? "\(rawValue)초" : "\(rawValue / 60)분" }
}

/// A paired unit is one status item and one priority/space-budget unit.
public enum MenuBarUnit: Hashable, Sendable {
    case metric(Metric), pair(Metric, Metric)
    public static var cpuGPU: Self { .pair(.cpu, .gpu) }
    public static var memorySSD: Self { .pair(.memory, .ssd) }
    public var metrics: [Metric] {
        switch self {
        case .metric(let metric): [metric]
        case .pair(let upper, let lower): [upper, lower]
        }
    }
    public var id: String {
        switch self {
        case .metric(let metric): metric.rawValue
        case .pair(let upper, let lower): "\(upper.rawValue)-\(lower.rawValue)"
        }
    }
    public var title: String { metrics.map(\.title).joined(separator: " / ") }
}

public struct MenuBarPair: Codable, Equatable, Hashable, Sendable {
    public let upper: Metric
    public let lower: Metric
    public init(_ upper: Metric, _ lower: Metric) { self.upper = upper; self.lower = lower }
    public var metrics: [Metric] { [upper, lower] }
    public var unit: MenuBarUnit { .pair(upper, lower) }
}

public struct MenuBarGrouping: Codable, Equatable, Sendable {
    public static let eligible: [Metric] = [.cpu, .memory, .ssd, .gpu, .power]
    public private(set) var pairs: [MenuBarPair]
    public init(cpuGPU: Bool = false, memorySSD: Bool = true) {
        self.init(pairs: (cpuGPU ? [MenuBarPair(.cpu, .gpu)] : []) +
                  (memorySSD ? [MenuBarPair(.memory, .ssd)] : []))
    }
    public init(pairs: [MenuBarPair]) {
        var seen: Set<Metric> = []
        self.pairs = pairs.filter { pair in
            guard pair.upper != pair.lower, pair.metrics.allSatisfy(Self.eligible.contains),
                  pair.metrics.allSatisfy({ !seen.contains($0) }) else { return false }
            seen.formUnion(pair.metrics)
            return true
        }
    }
    // Keep the old convenience API for clients; storage uses generic ordered pairs.
    public var cpuGPU: Bool {
        get { pairs.contains(MenuBarPair(.cpu, .gpu)) }
        set { setLegacyPair(MenuBarPair(.cpu, .gpu), enabled: newValue) }
    }
    public var memorySSD: Bool {
        get { pairs.contains(MenuBarPair(.memory, .ssd)) }
        set { setLegacyPair(MenuBarPair(.memory, .ssd), enabled: newValue) }
    }
    private mutating func setLegacyPair(_ pair: MenuBarPair, enabled: Bool) {
        if enabled {
            pairs.removeAll { !$0.metrics.filter(pair.metrics.contains).isEmpty }
            pairs.append(pair)
        } else { pairs.removeAll { $0 == pair } }
    }
    public func pair(containing metric: Metric) -> MenuBarPair? { pairs.first { $0.metrics.contains(metric) } }
    public func removing(_ metric: Metric) -> Self { Self(pairs: pairs.filter { !$0.metrics.contains(metric) }) }
    public func swapping(_ metric: Metric) -> Self {
        Self(pairs: pairs.map { $0.metrics.contains(metric) ? MenuBarPair($0.lower, $0.upper) : $0 })
    }
    /// Re-pair exactly two items; former partners become single items. A group's own partner swaps rows.
    public func pairing(_ source: Metric, with target: Metric) -> Self {
        guard source != target, Self.eligible.contains(source), Self.eligible.contains(target) else { return self }
        if pair(containing: target)?.metrics.contains(source) == true { return swapping(source) }
        return Self(pairs: removing(source).removing(target).pairs + [MenuBarPair(source, target)])
    }
    private enum CodingKeys: String, CodingKey { case pairs, cpuGPU, memorySSD }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pairs) {
            self.init(pairs: try container.decode([MenuBarPair].self, forKey: .pairs))
        } else {
            self.init(cpuGPU: try container.decodeIfPresent(Bool.self, forKey: .cpuGPU) ?? false,
                      memorySSD: try container.decodeIfPresent(Bool.self, forKey: .memorySSD) ?? true)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pairs, forKey: .pairs)
        // Older builds can still load the other monitoring preferences; custom pairs appear ungrouped there.
        try container.encode(cpuGPU, forKey: .cpuGPU)
        try container.encode(memorySSD, forKey: .memorySSD)
    }
    /// Place pairs at their first member's position; one disabled member leaves a normal single item.
    public func units(metrics: [Metric]) -> [MenuBarUnit] {
        let present = Set(metrics)
        var emitted: Set<MenuBarUnit> = []
        return metrics.compactMap { metric in
            let unit: MenuBarUnit
            if let pair = pair(containing: metric), present.isSuperset(of: pair.metrics) { unit = pair.unit }
            else { unit = .metric(metric) }
            return emitted.insert(unit).inserted ? unit : nil
        }
    }
    /// The highest-priority member supplies the pair's priority; presentation order stays independent.
    public func rankedUnits(configuration: MonitorConfiguration, priority: [Metric]) -> [MenuBarUnit] {
        let units = units(metrics: configuration.visible)
        let ranked = MenuBarDensity.normalizedPriority(priority)
        return units.sorted { lhs, rhs in
            ranked.firstIndex(where: lhs.metrics.contains)! < ranked.firstIndex(where: rhs.metrics.contains)!
        }
    }
}
