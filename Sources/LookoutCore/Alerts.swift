import Foundation

public struct AlertRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var threshold: Double
    public var duration: TimeInterval
    public var metric: Metric? { Metric(rawValue: id) }
    public init(metric: Metric, enabled: Bool = false, threshold: Double, duration: TimeInterval) {
        id = metric.rawValue; self.enabled = enabled; self.threshold = threshold; self.duration = duration
    }
    public var recoveryThreshold: Double {
        switch metric {
        case .ssd: threshold + 5
        default: max(0, threshold - 10)
        }
    }
    public var thresholdRange: ClosedRange<Double> {
        switch metric { case .ssd: 1...1000; default: 1...100 }
    }
    public var unit: String { metric == .ssd ? "GB" : "%" }
    public var condition: String {
        switch metric { case .ssd: L10n.text("미만"); default: L10n.text("이상") }
    }
    public var recoveryDescription: String {
        let direction = metric == .ssd ? L10n.text("이상") : L10n.text("이하")
        return L10n.text("\(Int(recoveryThreshold)) \(unit) \(direction) 10초 유지 시 해제")
    }
    public func isTriggered(_ value: Double) -> Bool {
        switch metric { case .ssd: value < threshold; default: value >= threshold }
    }
    public func isRecovered(_ value: Double) -> Bool {
        metric == .ssd ? value >= recoveryThreshold : value <= recoveryThreshold
    }
    fileprivate func normalized() -> AlertRule {
        var rule = self
        let fallback = AlertConfiguration.defaults.first { $0.id == id }!
        rule.threshold = threshold.isFinite ? min(thresholdRange.upperBound, max(thresholdRange.lowerBound, threshold.rounded())) : fallback.threshold
        rule.duration = duration.isFinite ? min(300, max(0, duration)) : fallback.duration
        return rule
    }
}

public struct AlertConfiguration: Codable, Equatable, Sendable {
    public static let supportedMetrics: [Metric] = [.cpu, .memory, .ssd, .gpu]
    public static let defaults: [AlertRule] = [
        AlertRule(metric: .cpu, threshold: 90, duration: 30),
        AlertRule(metric: .memory, threshold: 90, duration: 60),
        AlertRule(metric: .ssd, threshold: 20, duration: 10),
        AlertRule(metric: .gpu, threshold: 90, duration: 30)
    ]
    public var rules: [AlertRule]
    public var sound: Bool
    public init(rules: [AlertRule] = Self.defaults, sound: Bool = false) {
        self.rules = rules; self.sound = sound
    }
    public var normalized: AlertConfiguration {
        var seen: Set<String> = []
        let migrated = rules.map { rule in
            var rule = rule
            if rule.id == Metric.disk.rawValue { rule.id = Metric.ssd.rawValue }
            return rule
        }
        let rules = (migrated + Self.defaults).filter {
            guard let metric = $0.metric, Self.supportedMetrics.contains(metric) else { return false }
            return seen.insert($0.id).inserted
        }.map { $0.normalized() }
        return AlertConfiguration(rules: rules, sound: sound)
    }
    public func rule(for metric: Metric) -> AlertRule {
        normalized.rules.first { $0.metric == metric } ?? AlertRule(metric: metric, threshold: 90, duration: 30)
    }
    public func hasEnabledRules(monitored: Set<Metric>) -> Bool {
        normalized.rules.contains { $0.enabled && $0.metric.map(monitored.contains) == true }
    }
}

public struct AlertEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let rule: AlertRule
    public let firstDetected: Date
    public var observedAt: Date
    public var value: Double
    public var metric: Metric { rule.metric! }
    public var title: String {
        switch metric {
        case .ssd: L10n.text("SSD 여유 공간 부족")
        default: L10n.text("\(metric.title) 사용률 높음")
        }
    }
    public var message: String {
        let value = metric == .ssd ? String(format: "%.1f GB", value) : ValueFormat.percent(value)
        return L10n.text("\(metric == .ssd ? L10n.text("여유") : L10n.text("사용률")) \(value) · 기준 \(Int(rule.threshold)) \(rule.unit) \(rule.condition)")
    }
}

/// A latched episode emits once and must recover before it can emit again.
/// Durations use monotonic uptime; missing samples and long gaps never count as sustained load.
public struct AlertEngine: Sendable {
    private struct State: Sendable {
        var rule: AlertRule
        var pendingSince: TimeInterval?
        var recoverySince: TimeInterval?
        var lastSample: TimeInterval?
        var active: AlertEvent?
        var notificationEligible = false
    }
    private var states: [Metric: State] = [:]
    public init(restored: [AlertEvent] = []) {
        for original in restored {
            var rule = original.rule
            if rule.id == Metric.disk.rawValue { rule.id = Metric.ssd.rawValue }
            let event = AlertEvent(id: original.id, rule: rule, firstDetected: original.firstDetected,
                                   observedAt: original.observedAt, value: original.value)
            guard let metric = event.rule.metric, AlertConfiguration.supportedMetrics.contains(metric),
                  event.rule.enabled, event.rule == event.rule.normalized(), event.value.isFinite else { continue }
            states[metric] = State(rule: event.rule, active: event)
        }
    }
    public var active: [AlertEvent] {
        AlertConfiguration.supportedMetrics.compactMap { states[$0]?.active }
    }
    public var notificationEligibleIDs: Set<UUID> {
        Set(states.values.filter(\.notificationEligible).compactMap { $0.active?.id })
    }
    public mutating func configure(_ configuration: AlertConfiguration, monitored: Set<Metric>) {
        let rules = configuration.normalized.rules.filter { $0.enabled && $0.metric.map(monitored.contains) == true }
        let allowed = Set(rules.compactMap(\.metric))
        for metric in Array(states.keys) where !allowed.contains(metric) { states.removeValue(forKey: metric) }
        for rule in rules {
            let metric = rule.metric!
            if states[metric]?.rule != rule { states[metric] = State(rule: rule) }
        }
    }
    public mutating func breakContinuity() {
        for metric in Array(states.keys) {
            states[metric]?.pendingSince = nil
            states[metric]?.recoverySince = nil
            states[metric]?.lastSample = nil
            states[metric]?.notificationEligible = false
        }
    }
    @discardableResult
    public mutating func evaluate(_ readings: [MetricReading], configuration: AlertConfiguration,
                                  monitored: Set<Metric>, uptime: TimeInterval, interval: Int) -> [AlertEvent] {
        configure(configuration, monitored: monitored)
        var events: [AlertEvent] = []
        let readings = Dictionary(readings.map { ($0.metric, $0) }, uniquingKeysWith: { _, latest in latest })
        for metric in AlertConfiguration.supportedMetrics {
            guard var state = states[metric] else { continue }
            guard let reading = readings[metric] else {
                state.pendingSince = nil; state.recoverySince = nil; state.lastSample = nil
                state.notificationEligible = false
                states[metric] = state; continue
            }
            guard let value = value(for: reading), value.isFinite else {
                state.pendingSince = nil; state.recoverySince = nil; state.lastSample = nil
                state.notificationEligible = false
                states[metric] = state; continue
            }
            let sampleUptime: Double
            let observedAt: Date
            if case .storage(let capacity) = reading.value {
                sampleUptime = capacity.uptime ?? uptime
                observedAt = capacity.sampledAt ?? reading.date
                // Reusing a cached capacity is not another confirming observation.
                if state.lastSample == sampleUptime { continue }
            } else { sampleUptime = uptime; observedAt = reading.date }
            let allowedGap: Double
            if case .storage(let capacity) = reading.value {
                allowedGap = max(75, Double(capacity.pollingInterval) * 2.5)
            } else { allowedGap = Double(interval) * 2.5 }
            if let previous = state.lastSample, sampleUptime <= previous || sampleUptime - previous > allowedGap {
                state.pendingSince = nil; state.recoverySince = nil
            }
            state.lastSample = sampleUptime
            if var active = state.active {
                active.value = value; active.observedAt = observedAt; state.active = active
                if state.rule.isRecovered(value) {
                    if state.recoverySince == nil { state.recoverySince = sampleUptime }
                    if sampleUptime - state.recoverySince! >= 10 {
                        state.active = nil; state.pendingSince = nil; state.recoverySince = nil
                    }
                } else { state.recoverySince = nil }
            } else if state.rule.isTriggered(value) {
                if state.pendingSince == nil { state.pendingSince = sampleUptime }
                if sampleUptime - state.pendingSince! >= state.rule.duration {
                    let event = AlertEvent(id: UUID(), rule: state.rule, firstDetected: observedAt,
                                           observedAt: observedAt, value: value)
                    state.active = event; state.pendingSince = nil; events.append(event)
                }
            } else { state.pendingSince = nil }
            state.notificationEligible = state.active != nil && state.rule.isTriggered(value)
            states[metric] = state
        }
        return events
    }
    private func value(for reading: MetricReading) -> Double? {
        switch (reading.metric, reading.value) {
        case (.cpu, .cpu(let value)): return (0...100).contains(value) ? value : nil
        case (.memory, .memory(let value)): return value.percent
        case (.gpu, .gpu(let value)): return (0...100).contains(value.utilization) ? value.utilization : nil
        case (.ssd, .storage(let value)): return value.total > 0 ? value.available / 1e9 : nil
        default: return nil
        }
    }
}
