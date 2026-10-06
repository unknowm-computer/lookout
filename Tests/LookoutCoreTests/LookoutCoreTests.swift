import Foundation
import LookoutCore
import Testing

@Test func cpuUsesTickDifferencesAndRejectsReset() {
    let old = CPUTicks(user: 100, system: 100, idle: 800)
    let current = CPUTicks(user: 125, system: 125, idle: 850)
    #expect(current.usage(since: old) == 50)
    #expect(old.usage(since: old) == nil)
    #expect(old.usage(since: current) == nil)
}

@Test func networkUsesActualElapsedTimeAndOneInterface() {
    let old = NetworkCounter(name: "en0", received: 1_000, sent: 500, uptime: 10)
    let current = NetworkCounter(name: "en0", received: 5_000, sent: 1_500, uptime: 14)
    #expect(current.rate(since: old)?.download == 1_000)
    #expect(current.rate(since: old)?.upload == 250)
    #expect(NetworkCounter(name: "utun0", received: 5_000, sent: 1_500, uptime: 14).rate(since: old) == nil)
    #expect(NetworkCounter(name: "en0", received: 0, sent: 0, uptime: 14).rate(since: old) == nil)
    #expect(old.rate(since: old) == nil)
    #expect(NetworkCounter(name: "en0", received: 1_000, sent: 500, uptime: 14).rate(since: old)?.download == 0)
}

@Test func settingsPreserveAllDisabledAndIgnoreUnknownIdentifiers() throws {
    let json = Data(#"{"version":1,"enabled":[],"order":["network","future","network","cpu"],"interval":99}"#.utf8)
    let config = try JSONDecoder().decode(SettingsRecord.self, from: json).configuration
    #expect(config.enabled.isEmpty)
    #expect(config.order == [.network, .cpu, .memory, .ssd, .disk, .power, .gpu])
    #expect(config.interval == 2)
    let record = SettingsRecord(configuration: config)
    #expect(try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(record)).configuration == config)
}

@Test func memoryStoragePreferenceMigratesToIndependentSSDAndPersistsExplicitOff() throws {
    let legacy = Data(#"{"version":1,"enabled":["memory"],"order":["cpu","memory","gpu"],"interval":3}"#.utf8)
    var config = try JSONDecoder().decode(SettingsRecord.self, from: legacy).configuration
    #expect(config.enabled == [.memory, .ssd] && config.needsStorageCapacity)
    #expect(config.order.prefix(4) == [.cpu, .memory, .ssd, .gpu])
    #expect(config.storageInterval == 30 && config.menuBarGrouping.memorySSD && !config.menuBarGrouping.cpuGPU)
    config.enabled.remove(.ssd)
    config.storageInterval = 300
    config.menuBarGrouping = MenuBarGrouping(cpuGPU: true, memorySSD: false)
    let restored = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: config))).configuration
    #expect(restored == config && !restored.needsStorageCapacity)
    #expect(restored.enabled == [.memory] && restored.interval == 3)
    let disabled = Data(#"{"version":1,"enabled":["memory","disk"],"showsMemoryStorage":false}"#.utf8)
    #expect(!(try JSONDecoder().decode(SettingsRecord.self, from: disabled).configuration.enabled.contains(.ssd)))
}

@Test func disabledMemoryAndPlatformFilteringPreserveIndependentSSD() throws {
    let original = MonitorConfiguration(enabled: [.power, .ssd], storageInterval: 1800)
    var restored = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: original))).configuration
    restored = MonitoringCapabilities(supportsProcessEnergy: false).applying(to: restored)
    #expect(restored.enabled == [.ssd] && restored.needsStorageCapacity && restored.storageInterval == 1800)
    #expect(MonitorConfiguration(storageInterval: -1).storageInterval == 30)
}

@Test func independentSSDDoesNotRequireRAMOrDiskActivity() async {
    let sampler = MetricSampler()
    let readings = await sampler.collect(MonitorConfiguration(enabled: [.ssd]))
    #expect(readings.count == 1 && readings.first?.metric == .ssd)
    if case .storage(let capacity) = readings.first?.value {
        #expect(capacity.total > 0 && capacity.percent.isFinite && capacity.sampledAt != nil)
    } else { Issue.record("SSD sampling should succeed on the startup volume") }
    #expect(await sampler.invocationCounts()[.disk] == nil)
    #expect(await sampler.invocationCounts()[.memory] == nil)
    let ram = await sampler.collect(MonitorConfiguration(enabled: [.memory]))
    #expect(ram.count == 1 && ram.first?.metric == .memory)
}

@Test func historyIsBoundedByTimeAndCountAndKeepsGaps() {
    var history = HistoryBuffer()
    let start = Date(timeIntervalSince1970: 1000)
    for i in 0..<700 {
        history.append(MetricReading(metric: .cpu, date: start.addingTimeInterval(Double(i) / 2), value: .cpu(10)), interval: 1)
    }
    #expect(history.points.count == 301)
    #expect(history.points.allSatisfy { $0.date >= start.addingTimeInterval(349.5 - 300) })
    let segment = history.points.last?.segment
    history.append(MetricReading(metric: .cpu, date: start.addingTimeInterval(350), value: nil), interval: 1)
    history.append(MetricReading(metric: .cpu, date: start.addingTimeInterval(351), value: .cpu(0)), interval: 1)
    #expect(history.points.last?.primary == 0)
    #expect(history.points.last?.segment != segment)
    #expect(history.points.contains { $0.primary == nil })
    history.prune(at: start.addingTimeInterval(1000))
    #expect(history.points.isEmpty)
}

@Test func disabledCollectorsDoNotReadSystemAPIs() async {
    let sampler = MetricSampler()
    #expect(await sampler.collect(MonitorConfiguration(enabled: [])).isEmpty)
    #expect(await sampler.invocationCounts().isEmpty)
    _ = await sampler.collect(MonitorConfiguration(enabled: [.memory]))
    let counts = await sampler.invocationCounts()
    #expect(counts[.memory] == 1)
    #expect(counts[.cpu] == nil)
    #expect(counts[.network] == nil)
    #expect(counts[.disk] == nil)
    #expect(counts[.power] == nil)
    #expect(counts[.gpu] == nil)
}

@Test func diskUsesSharedFreeSpaceAndBoundsCapacity() {
    let disk = DiskReading(name: "Data", total: 1_000, available: 250)
    #expect(disk.used == 750)
    #expect(disk.percent == 75)
    #expect(DiskReading(name: "Data", total: 1_000, available: 2_000).percent == 0)
    #expect(DiskReading(name: "Data", total: 1_000, available: -1).percent == 100)
}

@Test func gpuDistinguishesRealZeroFromUnsupportedStatistics() {
    #expect(GPUReading.from(statistics: [:], name: "Unknown") == nil)
    #expect(GPUReading.from(statistics: ["Device Utilization %": 101], name: "Unknown") == nil)
    #expect(GPUReading.from(statistics: ["Device Utilization %": Double.nan], name: "Unknown") == nil)
    let idle = GPUReading.from(statistics: ["Device Utilization %": 0, "Renderer Utilization %": 25,
                                           "In use system memory": 1_048_576], name: "Apple GPU")
    #expect(idle?.utilization == 0)
    #expect(idle?.renderer == 25 && idle?.tiler == nil && idle?.sharedMemory == 1_048_576)
}

@Test func olderSettingsKeepSelectionsWhenMetricsAreAdded() throws {
    let json = Data(#"{"version":1,"enabled":["cpu","memory","network"],"order":["cpu","memory","network"],"interval":2}"#.utf8)
    let config = try JSONDecoder().decode(SettingsRecord.self, from: json).configuration
    #expect(config.enabled == [.cpu, .memory, .ssd, .network])
    #expect(config.order == Metric.allCases)
    var enabled = config
    enabled.enabled.formUnion([.disk, .power, .gpu])
    #expect(try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: enabled))).configuration == enabled)
}

@MainActor private final class FakePreferences: SpacingPreferences {
    var values: SpacingValues
    var failNextWrite = false
    init(_ values: SpacingValues) { self.values = values }
    func read() throws -> SpacingValues { values }
    func write(_ values: SpacingValues) throws {
        if failNextWrite {
            failNextWrite = false
            self.values = SpacingValues(spacing: values.spacing, padding: self.values.padding)
            throw SpacingError.storage
        }
        self.values = values
    }
}

@MainActor private final class FakePersistence: SpacingPersistence {
    var transaction: SpacingTransaction?
    func load() throws -> SpacingTransaction? { transaction }
    func save(_ transaction: SpacingTransaction?) throws { self.transaction = transaction }
}

@Test @MainActor func spacingRestoresAbsentKeysAndOriginalTypesAcrossRelaunch() throws {
    let original = SpacingValues(spacing: try PreferenceSnapshot(value: nil), padding: try PreferenceSnapshot(value: 8.5))
    let preferences = FakePreferences(original), persistence = FakePersistence()
    let engine = try SpacingEngine(preferences: preferences, persistence: persistence)
    try engine.apply(spacing: 4, padding: 6)
    try engine.apply(spacing: 12, padding: 12)
    #expect(persistence.transaction?.original == original)
    let relaunched = try SpacingEngine(preferences: preferences, persistence: persistence)
    try relaunched.restore()
    #expect(preferences.values == original)
    #expect(try preferences.values.spacing.value() == nil)
    #expect((try preferences.values.padding.value() as? NSNumber)?.doubleValue == 8.5)
    #expect(persistence.transaction == nil)
}

@Test @MainActor func spacingRejectsExternalChangesUntilExplicitRestore() throws {
    let original = try SpacingValues(spacing: 9, padding: 9)
    let preferences = FakePreferences(original), persistence = FakePersistence()
    let engine = try SpacingEngine(preferences: preferences, persistence: persistence)
    try engine.apply(spacing: 4, padding: 4)
    preferences.values = try SpacingValues(spacing: 16, padding: 16)
    #expect(throws: SpacingError.self) { try engine.restore() }
    #expect(preferences.values == (try SpacingValues(spacing: 16, padding: 16)))
    try engine.restore(overridingExternalChange: true)
    #expect(preferences.values == original)
}

@Test @MainActor func spacingRollsBackPartialWrite() throws {
    let original = try SpacingValues(spacing: 9, padding: 9)
    let preferences = FakePreferences(original), persistence = FakePersistence()
    let engine = try SpacingEngine(preferences: preferences, persistence: persistence)
    preferences.failNextWrite = true
    #expect(throws: SpacingError.self) { try engine.apply(spacing: 4, padding: 4) }
    #expect(preferences.values == original)
    #expect(persistence.transaction == nil)
}
