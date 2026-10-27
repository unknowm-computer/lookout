import Foundation
@testable import LookoutCore
import Testing

private func coolingReading(_ temperature: Double = 60, canControl: Bool = true, minimum: Double = 1500,
                            maximum: Double = 5000) -> CoolingReading {
    CoolingReading(cpu: temperature, gpu: temperature - 5, fans: [
        CoolingFan(id: 0, rpm: 1700, minimum: minimum, maximum: maximum, automatic: true),
        CoolingFan(id: 1, rpm: 1800, minimum: minimum, maximum: maximum + 300, automatic: true)
    ], uptime: 5, canControl: canControl)
}

@Test func coolingProfilesAreOrderedBoundedAndRejectInvalidTemperature() {
    for temperature in stride(from: 0.0, through: 120, by: 1) {
        let comfortable = CoolingMode.comfortable.fraction(at: temperature)!
        let intensive = CoolingMode.intensive.fraction(at: temperature)!
        #expect((0...1).contains(comfortable))
        #expect(intensive >= comfortable && intensive <= 1)
    }
    #expect(CoolingMode.system.fraction(at: 60) == nil)
    #expect(CoolingMode.comfortable.fraction(at: .nan) == nil)
    #expect(CoolingMode.intensive.fraction(at: 200) == nil)
}

@Test func coolingPolicyUsesEachFansBoundsAndLimitsRamps() throws {
    var policy = CoolingControlPolicy()
    let reading = coolingReading(85)
    let firstResult = policy.targets(mode: .comfortable, reading: reading, elapsed: 3)
    let first = try #require(firstResult)
    #expect(first == [0: 2300, 1: 2400])
    let secondResult = policy.targets(mode: .comfortable, reading: coolingReading(25), elapsed: 3)
    let second = try #require(secondResult)
    #expect(second == [0: 2120, 1: 2220])
    let emergencyResult = policy.targets(mode: .comfortable, reading: coolingReading(96), elapsed: 3)
    let emergency = try #require(emergencyResult)
    #expect(emergency == [0: 5000, 1: 5300])
    policy.reset()
    #expect(policy.targets(mode: .comfortable, reading: reading, elapsed: 3) == first)
}

@Test func coolingPolicyRefusesMissingSensorsUnsupportedHardwareAndInvalidFans() {
    var policy = CoolingControlPolicy()
    #expect(policy.targets(mode: .system, reading: coolingReading(), elapsed: 3) == nil)
    #expect(policy.targets(mode: .comfortable, reading: coolingReading(canControl: false), elapsed: 3) == nil)
    #expect(policy.targets(mode: .comfortable, reading: coolingReading(.nan), elapsed: 3) == nil)
    #expect(policy.targets(mode: .comfortable, reading: coolingReading(minimum: 9000), elapsed: 3) == nil)
    let missing = CoolingReading(cpu: nil, gpu: nil, fans: [], uptime: 0, canControl: true)
    #expect(policy.targets(mode: .intensive, reading: missing, elapsed: 3) == nil)
    let duplicate = CoolingReading(cpu: 70, gpu: 60, fans: [coolingReading().fans[0], coolingReading().fans[0]], uptime: 0, canControl: true)
    #expect(policy.targets(mode: .comfortable, reading: duplicate, elapsed: 3) == nil)
}

@Test func coolingTemperatureBandHasHysteresisAndUsesHotterThermalZone() {
    #expect(CoolingTemperatureBand.normal.updating(temperature: 75) == .warm)
    #expect(CoolingTemperatureBand.warm.updating(temperature: 73) == .warm)
    #expect(CoolingTemperatureBand.warm.updating(temperature: 71) == .normal)
    #expect(CoolingTemperatureBand.normal.updating(temperature: 90) == .hot)
    #expect(CoolingTemperatureBand.hot.updating(temperature: 88) == .hot)
    #expect(CoolingTemperatureBand.hot.updating(temperature: 86) == .warm)
    #expect(coolingReading(60).temperature == 60)
}

@Test func oldSettingsKeepSelectionsAndPersistNewCoolingChoice() throws {
    let old = try JSONDecoder().decode(SettingsRecord.self, from: Data(#"{"version":2,"enabled":["memory","cpu"],"order":["memory","cpu"],"interval":5}"#.utf8))
    #expect(old.configuration.enabled == [.memory, .cpu])
    #expect(old.configuration.visible == [.memory, .cpu])
    var config = old.configuration
    config.enabled.insert(.cooling)
    let reloaded = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: config)))
    #expect(reloaded.configuration.enabled.contains(.cooling))
    #expect(reloaded.configuration.interval == 5)
}

@Test func coolingDefaultsOffButExplicitSavedChoicesArePreserved() throws {
    #expect(!MonitorConfiguration().enabled.contains(.cooling))
    let unspecified = try JSONDecoder().decode(SettingsRecord.self, from: Data(#"{"version":2}"#.utf8))
    #expect(!unspecified.configuration.enabled.contains(.cooling))
    let selections: [Set<Metric>] = [[.cpu], [.cpu, .cooling]]
    for enabled in selections {
        let config = MonitorConfiguration(enabled: enabled)
        let saved = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: config)))
        #expect(saved.configuration.enabled == enabled)
    }
}

@Test func coolingCanPairWithCPUAndUnsupportedPlatformsOnlyFilterRuntimeSelection() {
    let grouping = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .cooling)])
    let config = MonitorConfiguration(enabled: [.cpu, .cooling], menuBarGrouping: grouping)
    #expect(grouping.units(metrics: config.visible).first?.metrics == [.cpu, .cooling])
    let unsupported = MonitoringCapabilities(supportsGPU: true, supportsProcessEnergy: true, supportsCooling: false)
    #expect(unsupported.applying(to: config).visible == [.cpu])
    #expect(unsupported.applying(to: config).menuBarGrouping == grouping)
    #expect(ValueFormat.temperature(65.4) == "65°C")
    #expect(ValueFormat.temperature(.nan) == "—")
    #expect(ValueFormat.rpm(1700) == "1700 RPM")
}

@Test func coolingLeaseExpiresAndRejectsClockResetsAndNonfiniteValues() {
    #expect(CoolingControlPolicy.leaseIsValid(lastHeartbeat: 10, now: 24))
    #expect(!CoolingControlPolicy.leaseIsValid(lastHeartbeat: 10, now: 26))
    #expect(!CoolingControlPolicy.leaseIsValid(lastHeartbeat: 10, now: 9))
    #expect(!CoolingControlPolicy.leaseIsValid(lastHeartbeat: .nan, now: 10))
    #expect(!CoolingControlPolicy.leaseIsValid(lastHeartbeat: 10, now: .infinity))
}

@Test func coolingAllowsThreeIndependentPairsWithoutIncludingIORates() {
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .cooling), MenuBarPair(.memory, .ssd), MenuBarPair(.gpu, .power)])
    #expect(groups.pairs.count == 3)
    #expect(groups.pairing(.network, with: .cooling) == groups)
    #expect(groups.pairing(.disk, with: .cooling) == groups)
}

@Test func coolingHistoryKeepsCPUAndGPUSeparateWhenTheHotterZoneChanges() {
    let date = Date(timeIntervalSince1970: 1000)
    var history = HistoryBuffer()
    for (index, temperatures) in [(72.0, 65.0), (68.0, 80.0)].enumerated() {
        let value = CoolingReading(cpu: temperatures.0, gpu: temperatures.1, fans: [], uptime: Double(index), canControl: false)
        let live = ReadingValue.cooling(value)
        #expect(live.primary == max(temperatures.0, temperatures.1))
        history.append(MetricReading(metric: .cooling, date: date.addingTimeInterval(Double(index) * 5), value: live), interval: 5)
    }
    #expect(history.points.map(\.primary) == [72, 68])
    #expect(history.points.map(\.secondary) == [65, 80])
    #expect(history.points[0].segment == history.points[1].segment)
}

@Test func coolingHistoryDoesNotSubstituteTheOtherSensorForMissingTemperature() {
    var history = HistoryBuffer()
    let date = Date(timeIntervalSince1970: 1000)
    let value = CoolingReading(cpu: nil, gpu: 70, fans: [], uptime: 1, canControl: false)
    history.append(MetricReading(metric: .cooling, date: date, value: .cooling(value)), interval: 5)
    #expect(history.points.last?.primary == nil)
    #expect(history.points.last?.secondary == 70)
    history.append(MetricReading(metric: .cooling, date: date.addingTimeInterval(5), value: nil), interval: 5)
    #expect(history.points.last?.primary == nil)
    #expect(history.points.last?.secondary == nil)
    #expect(history.points[0].segment != history.points[1].segment)
}
