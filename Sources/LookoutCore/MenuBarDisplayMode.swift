import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Sendable, Identifiable {
    case individual, combined
    public var id: String { rawValue }
    public var title: String {
        switch self { case .individual: "항목별 표시"; case .combined: "통합 표시" }
    }
}

public enum MenuBarDensity: String, CaseIterable, Sendable, Identifiable {
    case automatic, normal, compact, minimal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "자동"; case .normal: "일반"
        case .compact: "축소"; case .minimal: "최소"
        }
    }
    /// Presentation only: never alter collection, alerts or the full detail panel's selection.
    public func metrics(configuration: MonitorConfiguration, priority: [Metric], automaticLimit: Int? = nil) -> [Metric] {
        let visible = configuration.visible
        let limit: Int
        switch self {
        case .compact: limit = 2
        case .minimal: limit = 1
        case .normal: return visible
        case .automatic: limit = automaticLimit ?? configuration.menuBarGrouping.units(metrics: visible).count
        }
        let ranked = configuration.menuBarGrouping.rankedUnits(configuration: configuration, priority: priority)
        let retained = Set(ranked.prefix(max(1, limit)).flatMap(\.metrics))
        return visible.filter { retained.contains($0) }
    }
    public static func normalizedPriority(_ priority: [Metric]) -> [Metric] {
        var seen: Set<Metric> = []
        return (priority + Metric.allCases).filter { seen.insert($0).inserted }
    }
}

/// Keep the largest priority prefix that actually fits; do not reserve an extra recovery width.
public enum MenuBarSpacePolicy {
    public static func limit(widths: [Double], available: Double) -> Int? {
        guard !widths.isEmpty, available.isFinite,
              widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var total = 0.0
        var count = 0
        for width in widths {
            total += width
            guard total <= available else { break }
            count += 1
        }
        return max(1, count)
    }
    /// All coordinates must belong to the same selected screen, except the right-edge inset.
    public static func availableWidth(screenMinX: Double, screenMaxX: Double,
                                      safeMinX: Double, rightInset: Double) -> Double? {
        guard [screenMinX, screenMaxX, safeMinX, rightInset].allSatisfy(\.isFinite),
              screenMaxX > screenMinX, safeMinX >= screenMinX, safeMinX <= screenMaxX,
              rightInset >= 0 else { return nil }
        return screenMaxX - safeMinX - rightInset
    }
}

/// A time delay prevents flicker while still restoring all items as soon as their width fits.
public struct MenuBarExpansionGate: Sendable {
    private var candidate: Int?
    private var since = 0.0
    public init() {}
    public mutating func resolve(target: Int, current: Int, uptime: Double) -> Int {
        guard target > current else { candidate = nil; return target }
        if candidate != target || uptime < since {
            candidate = target
            since = uptime
        }
        guard uptime - since >= 1 else { return current }
        candidate = nil
        return target
    }
}
