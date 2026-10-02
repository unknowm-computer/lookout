import Foundation
import LookoutCore
import Testing

private func ruleConfig(_ metric: Metric = .cpu, threshold: Double = 90, duration: Double = 30) -> AlertConfiguration {
    AlertConfiguration(rules: [AlertRule(metric: metric, enabled: true, threshold: threshold, duration: duration)]).normalized
}
private func sample(_ metric: Metric = .cpu, _ value: ReadingValue?, at time: Double) -> MetricReading {
    MetricReading(metric: metric, date: Date(timeIntervalSince1970: time), value: value)
}
private func evaluate(_ engine: inout AlertEngine, _ value: Double?, at time: Double,
                      config: AlertConfiguration = ruleConfig(), monitored: Set<Metric> = [.cpu]) -> [AlertEvent] {
    engine.evaluate([sample(.cpu, value.map(ReadingValue.cpu), at: time)], configuration: config,
                    monitored: monitored, uptime: time, interval: 5)
}

@Test func alertsRequireSustainedLoadAndEmitOnce() {
    var engine = AlertEngine()
    for time in stride(from: 0.0, through: 25, by: 5) { #expect(evaluate(&engine, 95, at: time).isEmpty) }
    let event = evaluate(&engine, 95, at: 30)
    #expect(event.count == 1)
    for time in stride(from: 35.0, through: 100, by: 5) { #expect(evaluate(&engine, 99, at: time).isEmpty) }
    #expect(engine.active.first?.id == event.first?.id)
    #expect(engine.active.first?.value == 99)
}

@Test func alertsRecoverWithHysteresisAndRearmOnlyAfterRecovery() {
    var engine = AlertEngine()
    let config = ruleConfig(duration: 0)
    let first = evaluate(&engine, 95, at: 0, config: config).first
    #expect(first != nil)
    for time in stride(from: 5.0, through: 20, by: 5) { _ = evaluate(&engine, 85, at: time, config: config) }
    #expect(engine.active.first?.id == first?.id)
    _ = evaluate(&engine, 79, at: 25, config: config)
    _ = evaluate(&engine, 85, at: 30, config: config) // recovery must be continuous
    _ = evaluate(&engine, 79, at: 35, config: config)
    _ = evaluate(&engine, 79, at: 40, config: config)
    #expect(!engine.active.isEmpty)
    _ = evaluate(&engine, 79, at: 45, config: config)
    #expect(engine.active.isEmpty)
    let second = evaluate(&engine, 95, at: 50, config: config).first
    #expect(second != nil && second?.id != first?.id)
}

@Test func missingSamplesAndLongGapsDoNotCountTowardDuration() {
    var engine = AlertEngine()
    for time in stride(from: 0.0, through: 20, by: 5) { _ = evaluate(&engine, 95, at: time) }
    _ = evaluate(&engine, nil, at: 25)
    for time in stride(from: 30.0, through: 55, by: 5) { #expect(evaluate(&engine, 95, at: time).isEmpty) }
    #expect(evaluate(&engine, 95, at: 100).isEmpty) // gap resets a nearly complete timer
    for time in stride(from: 105.0, through: 125, by: 5) { #expect(evaluate(&engine, 95, at: time).isEmpty) }
    #expect(evaluate(&engine, 95, at: 130).count == 1)
    _ = evaluate(&engine, nil, at: 135)
    #expect(!engine.active.isEmpty) // unavailable is not recovery
    _ = evaluate(&engine, 70, at: 140)
    _ = evaluate(&engine, nil, at: 145)
    _ = evaluate(&engine, 70, at: 150)
    #expect(!engine.active.isEmpty)
    _ = evaluate(&engine, 70, at: 155)
    _ = evaluate(&engine, 70, at: 160)
    #expect(engine.active.isEmpty)
}

@Test func sleepBreaksPendingDurationButPreservesLatchedEpisode() {
    var engine = AlertEngine()
    _ = evaluate(&engine, 95, at: 0)
    _ = evaluate(&engine, 95, at: 5)
    engine.breakContinuity()
    #expect(evaluate(&engine, 95, at: 500).isEmpty)
    for time in stride(from: 505.0, through: 525, by: 5) { _ = evaluate(&engine, 95, at: time) }
    #expect(evaluate(&engine, 95, at: 530).count == 1)
    engine.breakContinuity()
    #expect(evaluate(&engine, 95, at: 900).isEmpty)
    #expect(engine.active.count == 1)
}

@Test func disablingMonitoringOrChangingRuleClearsEpisodes() {
    var engine = AlertEngine()
    let immediate = ruleConfig(duration: 0)
    _ = evaluate(&engine, 95, at: 0, config: immediate)
    _ = evaluate(&engine, 95, at: 5, config: immediate, monitored: [])
    #expect(engine.active.isEmpty)
    #expect(evaluate(&engine, 95, at: 10, config: immediate).count == 1)
    let changed = ruleConfig(threshold: 98, duration: 0)
    #expect(evaluate(&engine, 95, at: 15, config: changed).isEmpty)
    #expect(engine.active.isEmpty)
    _ = evaluate(&engine, 100, at: 20, config: changed)
    engine.configure(AlertConfiguration(), monitored: [.cpu])
    #expect(engine.active.isEmpty)
}

@Test func restoredEpisodesDoNotEmitAgainAndKeepRecoveryTimerFresh() throws {
    var engine = AlertEngine()
    let config = ruleConfig(duration: 0)
    _ = evaluate(&engine, 95, at: 0, config: config)
    let data = try JSONEncoder().encode(engine.active)
    let restored = try JSONDecoder().decode([AlertEvent].self, from: data)
    var relaunched = AlertEngine(restored: restored)
    #expect(relaunched.notificationEligibleIDs.isEmpty)
    #expect(evaluate(&relaunched, 95, at: 100, config: config).isEmpty)
    #expect(relaunched.notificationEligibleIDs == Set(restored.map(\.id)))
    #expect(relaunched.active.first?.id == restored.first?.id)
    _ = evaluate(&relaunched, 70, at: 105, config: config)
    #expect(relaunched.notificationEligibleIDs.isEmpty)
    _ = evaluate(&relaunched, 70, at: 110, config: config)
    #expect(!relaunched.active.isEmpty)
    _ = evaluate(&relaunched, 70, at: 115, config: config)
    #expect(relaunched.active.isEmpty)
}

@Test func notificationEligibilityRequiresCurrentValidThresholdViolation() {
    var engine = AlertEngine()
    let config = ruleConfig(duration: 0)
    _ = evaluate(&engine, 95, at: 0, config: config)
    let id = engine.active.first!.id
    #expect(engine.notificationEligibleIDs == [id])
    _ = evaluate(&engine, nil, at: 5, config: config)
    #expect(engine.notificationEligibleIDs.isEmpty && engine.active.first?.id == id)
    _ = evaluate(&engine, 85, at: 10, config: config)
    #expect(engine.notificationEligibleIDs.isEmpty && engine.active.first?.id == id)
    _ = evaluate(&engine, 95, at: 15, config: config)
    #expect(engine.notificationEligibleIDs == [id])
    engine.breakContinuity()
    #expect(engine.notificationEligibleIDs.isEmpty && engine.active.first?.id == id)
}

@Test func previousBatteryAlertSettingsAndEpisodesAreRetired() throws {
    let oldRule = AlertRule(metric: .power, enabled: true, threshold: 20, duration: 10)
    let oldEvent = try JSONDecoder().decode(AlertEvent.self, from: Data(#"{"id":"A5A85460-746D-4BCE-A68F-047422D47973","rule":{"id":"power","enabled":true,"threshold":20,"duration":10},"firstDetected":0,"observedAt":0,"value":10}"#.utf8))
    let config = AlertConfiguration(rules: [oldRule, AlertRule(metric: .cpu, enabled: true, threshold: 80, duration: 30)]).normalized
    #expect(config.rules.allSatisfy { $0.metric != .power })
    #expect(config.rule(for: .cpu).enabled)
    #expect(!AlertConfiguration(rules: [oldRule]).hasEnabledRules(monitored: [.power]))
    var engine = AlertEngine(restored: [oldEvent])
    #expect(engine.active.isEmpty)
    let readings = [sample(.power, .power(PowerReading(watts: 10)), at: 0)]
    #expect(engine.evaluate(readings, configuration: config, monitored: [.power], uptime: 0, interval: 2).isEmpty)
}

@Test func diskAlertUsesFreeGBRatherThanUsedPercent() {
    var engine = AlertEngine()
    let config = ruleConfig(.disk, threshold: 20, duration: 0)
    func check(_ free: Double, at time: Double) -> [AlertEvent] {
        engine.evaluate([sample(.disk, .disk(DiskReading(name: "Data", total: 1e12, available: free * 1e9)), at: time)],
                        configuration: config, monitored: [.disk], uptime: time, interval: 5)
    }
    #expect(check(20, at: 0).isEmpty)
    #expect(check(19, at: 5).count == 1)
    #expect(engine.active.first?.value == 19)
    _ = check(24, at: 10)
    _ = check(25, at: 15)
    _ = check(25, at: 20)
    #expect(!engine.active.isEmpty)
    _ = check(25, at: 25)
    #expect(engine.active.isEmpty)
}

@Test func alertSettingsNormalizeUnknownInvalidAndDuplicateRules() throws {
    let data = Data(#"{"rules":[{"id":"future","enabled":true,"threshold":90,"duration":1},{"id":"cpu","enabled":true,"threshold":200,"duration":-1},{"id":"cpu","enabled":false,"threshold":1,"duration":1}],"sound":true}"#.utf8)
    let configuration = try JSONDecoder().decode(AlertConfiguration.self, from: data).normalized
    #expect(configuration.rules.count == 4 && configuration.sound)
    #expect(configuration.rule(for: .cpu).threshold == 100 && configuration.rule(for: .cpu).duration == 0)
    #expect(configuration.rule(for: .cpu).enabled)
    #expect(!configuration.rule(for: .memory).enabled)
    #expect(try JSONDecoder().decode(AlertConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    #expect(!configuration.hasEnabledRules(monitored: [.memory]))
    #expect(configuration.hasEnabledRules(monitored: [.cpu]))
}

@Test func unsupportedGpuAndInvalidReadingsNeverTrigger() {
    var engine = AlertEngine()
    let config = ruleConfig(.gpu, duration: 0)
    #expect(engine.evaluate([sample(.gpu, nil, at: 0)], configuration: config, monitored: [.gpu], uptime: 0, interval: 5).isEmpty)
    #expect(engine.evaluate([sample(.gpu, .gpu(GPUReading(name: "GPU", utilization: 0, renderer: nil, tiler: nil, sharedMemory: nil)), at: 5)],
                            configuration: config, monitored: [.gpu], uptime: 5, interval: 5).isEmpty)
    #expect(evaluate(&engine, Double.nan, at: 10, config: ruleConfig(duration: 0)).isEmpty)
    #expect(engine.active.isEmpty)
}
