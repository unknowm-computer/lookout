import Foundation
import LookoutCore
import Testing

private func temperatureAlerts(duration: Double = 10) -> AlertConfiguration {
    AlertConfiguration(rules: [AlertRule(metric: .cooling, enabled: true, threshold: 90, duration: duration)])
}

private func temperatureSample(cpu: Double?, gpu: Double?, sampledAt: Double, now: Double? = nil) -> MetricReading {
    MetricReading(metric: .cooling, date: Date(timeIntervalSince1970: now ?? sampledAt),
        value: .cooling(CoolingReading(cpu: cpu, gpu: gpu, fans: [], uptime: sampledAt, canControl: false)))
}

@Test func temperatureAlertMigrationPreservesExistingRulesAndDefaultsToOff() throws {
    let data = Data(#"{"rules":[{"id":"cpu","enabled":true,"threshold":83,"duration":60}],"sound":true}"#.utf8)
    let migrated = try JSONDecoder().decode(AlertConfiguration.self, from: data).normalized
    let rule = migrated.rule(for: .cooling)
    #expect(!rule.enabled && rule.threshold == 90 && rule.duration == 30)
    #expect(rule.unit == "°C" && rule.recoveryThreshold == 85)
    #expect(migrated.rule(for: .cpu).enabled && migrated.rule(for: .cpu).threshold == 83 && migrated.sound)
    let normalized = AlertConfiguration(rules: [AlertRule(metric: .cooling, enabled: true, threshold: 150, duration: 400)]).normalized
    #expect(normalized.rule(for: .cooling).threshold == 120 && normalized.rule(for: .cooling).duration == 300)
    #expect(try JSONDecoder().decode(AlertConfiguration.self, from: JSONEncoder().encode(migrated)) == migrated)
}

@Test func temperatureAlertUsesHigherSensorAndFreshSamplesWithoutNeedingFanControl() throws {
    var engine = AlertEngine()
    let config = temperatureAlerts()
    func check(_ reading: MetricReading, now: Double) -> [AlertEvent] {
        engine.evaluate([reading], configuration: config, monitored: [.cooling], uptime: now, interval: 1)
    }
    #expect(check(temperatureSample(cpu: 65, gpu: 92, sampledAt: 0), now: 0).isEmpty)
    // Re-reading a cached temperature even much later does not confirm ten hot seconds.
    #expect(check(temperatureSample(cpu: 65, gpu: 92, sampledAt: 0, now: 10), now: 10).isEmpty)
    #expect(check(temperatureSample(cpu: 93, gpu: 65, sampledAt: 10), now: 10).count == 1)
    let event = try #require(engine.active.first)
    #expect(event.metric == .cooling && event.value == 93)
    #expect(event.message.contains(ValueFormat.temperature(93)) && !event.message.contains("%"))
    #expect(event.title == L10n.text("시스템 온도 높음"))
    #expect(check(temperatureSample(cpu: nil, gpu: 94, sampledAt: 15), now: 15).isEmpty)
    #expect(engine.active.first?.id == event.id && engine.active.first?.value == 94)
    #expect(engine.notificationEligibleIDs == [event.id])
}

@Test func temperatureAlertsRecoverWithFiveDegreeMarginAndRequireFreshRecoverySamples() {
    var engine = AlertEngine()
    let config = temperatureAlerts(duration: 0)
    func check(_ temperature: Double, at time: Double, sampledAt: Double? = nil) -> [AlertEvent] {
        engine.evaluate([temperatureSample(cpu: temperature, gpu: nil, sampledAt: sampledAt ?? time, now: time)],
                        configuration: config, monitored: [.cooling], uptime: time, interval: 3)
    }
    let first = check(90, at: 0).first
    #expect(first != nil)
    _ = check(86, at: 6)
    _ = check(85, at: 12)
    _ = check(85, at: 24, sampledAt: 12)
    #expect(engine.active.first?.id == first?.id)
    _ = check(85, at: 24)
    #expect(engine.active.isEmpty && engine.notificationEligibleIDs.isEmpty)
    let next = check(95, at: 30).first
    #expect(next != nil && next?.id != first?.id)
}

@Test func missingInvalidSleepingAndStaleTemperaturesDoNotAccumulateAlertDuration() {
    let config = temperatureAlerts()
    for invalid in [temperatureSample(cpu: nil, gpu: nil, sampledAt: 5),
                    temperatureSample(cpu: .nan, gpu: .infinity, sampledAt: 5),
                    temperatureSample(cpu: 130, gpu: -1, sampledAt: 5),
                    temperatureSample(cpu: 95, gpu: nil, sampledAt: .nan),
                    temperatureSample(cpu: 95, gpu: nil, sampledAt: 100)] {
        var engine = AlertEngine()
        _ = engine.evaluate([temperatureSample(cpu: 95, gpu: nil, sampledAt: 0)], configuration: config,
                            monitored: [.cooling], uptime: 0, interval: 1)
        #expect(engine.evaluate([invalid], configuration: config, monitored: [.cooling], uptime: 5, interval: 1).isEmpty)
        #expect(engine.evaluate([temperatureSample(cpu: 95, gpu: nil, sampledAt: 10)], configuration: config,
                               monitored: [.cooling], uptime: 10, interval: 1).isEmpty)
    }
    var engine = AlertEngine()
    _ = engine.evaluate([temperatureSample(cpu: 95, gpu: nil, sampledAt: 0)], configuration: config,
                        monitored: [.cooling], uptime: 0, interval: 1)
    engine.breakContinuity()
    #expect(engine.evaluate([temperatureSample(cpu: 95, gpu: nil, sampledAt: 10)], configuration: config,
                           monitored: [.cooling], uptime: 10, interval: 1).isEmpty)
    #expect(engine.evaluate([temperatureSample(cpu: 95, gpu: nil, sampledAt: 30)], configuration: config,
                           monitored: [.cooling], uptime: 30, interval: 1).isEmpty)
}

@Test func temperatureAlertsPauseWhenMonitoringOrRuleIsOffAndRestoreEpisodesWithoutDuplicates() throws {
    let config = temperatureAlerts(duration: 0)
    let reading = temperatureSample(cpu: nil, gpu: 95, sampledAt: 0)
    var engine = AlertEngine()
    #expect(engine.evaluate([reading], configuration: config, monitored: [], uptime: 0, interval: 5).isEmpty)
    #expect(engine.evaluate([reading], configuration: AlertConfiguration(), monitored: [.cooling], uptime: 0, interval: 5).isEmpty)
    let event = try #require(engine.evaluate([reading], configuration: config, monitored: [.cooling], uptime: 0, interval: 5).first)
    let saved = try JSONDecoder().decode([AlertEvent].self, from: JSONEncoder().encode([event]))
    var restored = AlertEngine(restored: saved)
    #expect(restored.notificationEligibleIDs.isEmpty)
    #expect(restored.evaluate([temperatureSample(cpu: 91, gpu: nil, sampledAt: 5)], configuration: config,
                             monitored: [.cooling], uptime: 5, interval: 5).isEmpty)
    #expect(restored.active.first?.id == event.id && restored.notificationEligibleIDs == [event.id])
    restored.configure(config, monitored: [])
    #expect(restored.active.isEmpty && restored.notificationEligibleIDs.isEmpty)
}
