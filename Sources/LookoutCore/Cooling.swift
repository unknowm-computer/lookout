import Foundation

public enum CoolingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, comfortable, intensive
    public var id: Self { self }
    public var title: String {
        switch self {
        case .system: L10n.text("시스템 자동")
        case .comfortable: L10n.text("쾌적")
        case .intensive: L10n.text("적극 냉각")
        }
    }
    public var description: String {
        switch self {
        case .system: L10n.text("macOS가 팬 속도를 조절합니다.")
        case .comfortable: L10n.text("온도가 오르면 팬을 일찍 가속합니다. 소음이 늘어날 수 있습니다.")
        case .intensive: L10n.text("소음보다 냉각을 우선합니다.")
        }
    }
    /// Initial M1 Pro profiles, not hardware temperature limits. No user temperature tuning.
    public func fraction(at temperature: Double) -> Double? {
        guard self != .system, temperature.isFinite, (0...120).contains(temperature) else { return nil }
        let start = self == .comfortable ? 45.0 : 35.0
        let full = self == .comfortable ? 80.0 : 70.0
        return min(1, max(0, (temperature - start) / (full - start)))
    }
}

public enum CoolingTemperatureBand: String, Codable, Sendable {
    case normal, warm, hot
    public var title: String {
        switch self {
        case .normal: L10n.text("일반")
        case .warm: L10n.text("온도 높음")
        case .hot: L10n.text("온도 매우 높음")
        }
    }
    /// Display categories only, with a 3°C recovery margin. Not a diagnosis of overheating.
    public func updating(temperature: Double) -> Self {
        if temperature >= 90 { return .hot }
        if self == .hot, temperature >= 87 { return .hot }
        if temperature >= 75 { return .warm }
        if self != .normal, temperature >= 72 { return .warm }
        return .normal
    }
}

public struct CoolingFan: Codable, Sendable, Identifiable, Equatable {
    public let id: Int
    public let rpm: Double
    public let minimum: Double
    public let maximum: Double
    public let target: Double?
    public let automatic: Bool?
    public var hasValidRange: Bool {
        rpm.isFinite && (0...12000).contains(rpm) && minimum.isFinite && maximum.isFinite
            && minimum >= 0 && maximum > minimum && maximum <= 12000
    }
    public var title: String {
        id == 0 ? L10n.text("왼쪽 팬") : L10n.text("오른쪽 팬")
    }
    public init(id: Int, rpm: Double, minimum: Double, maximum: Double, target: Double? = nil, automatic: Bool? = nil) {
        self.id = id; self.rpm = rpm; self.minimum = minimum; self.maximum = maximum
        self.target = target; self.automatic = automatic
    }
}

public struct CoolingReading: Codable, Sendable {
    public let cpu: Double?
    public let gpu: Double?
    public let fans: [CoolingFan]
    public let band: CoolingTemperatureBand
    public let uptime: Double
    public let canControl: Bool
    public var temperature: Double? { [cpu, gpu].compactMap { $0 }.max() }
    public init(cpu: Double?, gpu: Double?, fans: [CoolingFan], band: CoolingTemperatureBand = .normal,
                uptime: Double, canControl: Bool) {
        self.cpu = cpu; self.gpu = gpu; self.fans = fans; self.band = band; self.uptime = uptime; self.canControl = canControl
    }
}

/// Helper owns this policy. A client can choose a profile but cannot supply sensor values or RPMs.
public struct CoolingControlPolicy: Sendable {
    private var targets: [Int: Double] = [:]
    public init() {}
    public mutating func reset() { targets.removeAll() }
    public static func leaseIsValid(lastHeartbeat: Double, now: Double, maximumAge: Double = 15) -> Bool {
        lastHeartbeat.isFinite && now.isFinite && now >= lastHeartbeat && now - lastHeartbeat <= maximumAge
    }
    public mutating func targets(mode: CoolingMode, reading: CoolingReading, elapsed: Double) -> [Int: Double]? {
        guard reading.canControl, elapsed.isFinite, elapsed > 0,
              let cpu = reading.cpu, let gpu = reading.gpu, cpu.isFinite, gpu.isFinite,
              (1...120).contains(cpu), (1...120).contains(gpu), let temperature = reading.temperature,
              let fraction = mode.fraction(at: temperature), reading.fans.count == 2,
              Set(reading.fans.map(\.id)) == [0, 1], reading.fans.allSatisfy(\.hasValidRange) else { return nil }
        var result: [Int: Double] = [:]
        for fan in reading.fans {
            let desired = fan.minimum + (fan.maximum - fan.minimum) * fraction
            let previous = targets[fan.id] ?? max(fan.minimum, min(fan.maximum, fan.rpm))
            // Ramp down gently; reach maximum immediately for very high measured temperature.
            let step = max(0, min(10, elapsed)) * (desired >= previous ? 200 : 60)
            let next = temperature >= 95 ? fan.maximum : min(previous + step, max(previous - step, desired))
            result[fan.id] = min(fan.maximum, max(fan.minimum, next)).rounded()
        }
        targets = result
        return result
    }
}

extension ValueFormat {
    public static func temperature(_ value: Double) -> String {
        guard value.isFinite, (0...120).contains(value) else { return "—" }
        return String(format: "%.0f°C", value)
    }
    public static func rpm(_ value: Double) -> String {
        guard value.isFinite, (0...12000).contains(value) else { return "—" }
        return String(format: "%.0f RPM", value)
    }
}
