import Foundation

public enum MemoryPressure: UInt32, Sendable {
    // kern.memorystatus_vm_pressure_level returns dispatch flags, not the internal XNU enum.
    case normal = 1, warning = 2, critical = 4
    public var title: String {
        switch self { case .normal: L10n.text("정상"); case .warning: L10n.text("주의"); case .critical: L10n.text("부족") }
    }
}

public enum CapacityMenuBarValue: String, CaseIterable, Codable, Sendable, Identifiable {
    case percentage, used, available, availablePercentage
    public var id: Self { self }
    public var isPercentage: Bool { self == .percentage || self == .availablePercentage }
    public var capacity: Self { self == .available || self == .availablePercentage ? .available : .used }
    public init(capacity: Self, percentage: Bool) {
        self = capacity.capacity == .available
            ? (percentage ? .availablePercentage : .available)
            : (percentage ? .percentage : .used)
    }
    public var title: String {
        switch self {
        case .percentage: L10n.text("사용률")
        case .used: L10n.text("사용 용량")
        case .available: L10n.text("남은 용량")
        case .availablePercentage: L10n.text("남은 비율")
        }
    }
}

public enum TemperatureMenuBarValue: String, CaseIterable, Codable, Sendable, Identifiable {
    case both, cpu, gpu, hidden
    public var id: Self { self }
    public var title: String {
        switch self { case .both: L10n.text("둘 다"); case .cpu: "CPU"; case .gpu: "GPU"; case .hidden: L10n.text("숨김") }
    }
    public var metrics: [Metric] {
        switch self { case .both: [.cpu, .gpu]; case .cpu: [.cpu]; case .gpu: [.gpu]; case .hidden: [] }
    }
}

/// Display-only preferences must not restart collectors or change alert thresholds.
public struct MenuBarValuePreferences: Codable, Equatable, Sendable {
    public var memory: CapacityMenuBarValue
    public var storage: CapacityMenuBarValue
    public var temperature: TemperatureMenuBarValue
    public init(memory: CapacityMenuBarValue = .percentage, storage: CapacityMenuBarValue = .available,
                temperature: TemperatureMenuBarValue = .both) {
        self.memory = memory; self.storage = storage; self.temperature = temperature
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memory = (try? values.decode(CapacityMenuBarValue.self, forKey: .memory)) ?? .percentage
        storage = (try? values.decode(CapacityMenuBarValue.self, forKey: .storage)) ?? .available
        temperature = (try? values.decode(TemperatureMenuBarValue.self, forKey: .temperature)) ?? .both
    }
    public func mode(for metric: Metric) -> CapacityMenuBarValue {
        metric == .ssd ? storage : memory
    }
    /// A presentation-only copy for menu-bar grouping, priority and width calculations.
    /// Collection, fan control, alerts and detail views keep the original configuration.
    public func menuBarConfiguration(from configuration: MonitorConfiguration) -> MonitorConfiguration {
        var result = configuration
        if temperature == .hidden { result.enabled.remove(.cooling) }
        return result
    }
    public func text(for metric: Metric, value: ReadingValue?) -> String {
        switch value {
        case .memory(let memory) where metric == .memory:
            switch self.memory {
            case .percentage: ValueFormat.percent(memory.percent)
            case .availablePercentage: Self.remainingPercentage(available: memory.available, total: memory.total)
            case .used: ValueFormat.memory(memory.used)
            case .available: ValueFormat.memory(memory.available)
            }
        case .storage(let storage) where metric == .ssd:
            switch self.storage {
            case .percentage: ValueFormat.percent(storage.percent)
            case .availablePercentage: Self.remainingPercentage(available: storage.available, total: storage.total)
            case .used: ValueFormat.menuBarStorage(storage.used)
            case .available: ValueFormat.menuBarStorage(storage.available)
            }
        default: "—"
        }
    }
    private static func remainingPercentage(available: Double, total: Double) -> String {
        guard total.isFinite, total > 0, available.isFinite else { return "—" }
        return ValueFormat.percent(min(1, max(0, available / total)) * 100)
    }
}

extension ValueFormat {
    /// Compact SSD menu-bar values; detail views continue to use storage(_:).
    public static func menuBarStorage(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes, index = 0
        while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
        if value >= 100 || index == 0 {
            return String(format: "%.0f %@", floor(value), units[index])
        }
        return String(format: "%.1f %@", floor(value * 10) / 10, units[index])
    }
}
