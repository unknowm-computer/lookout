import Foundation
import LookoutCore
import Testing

@Test func cpuMemorySSDPlacementKeepsGroupsAtTheirUpperMemberAndHighestPriority() {
    let order: [Metric] = [.cpu, .memory, .ssd, .gpu, .network, .disk, .power]
    let priority: [Metric] = [.cpu, .memory, .ssd, .network, .disk, .power, .gpu]
    let grouped = MonitorConfiguration(order: order, menuBarGrouping: MenuBarGrouping(cpuGPU: true, memorySSD: true))
    #expect(grouped.menuBarGrouping.units(metrics: grouped.visible).prefix(2) == [.cpuGPU, .memorySSD])
    #expect(grouped.menuBarGrouping.rankedUnits(configuration: grouped, priority: priority).prefix(2) == [.cpuGPU, .memorySSD])
    #expect(MenuBarDensity.minimal.metrics(configuration: grouped, priority: priority) == [.cpu, .gpu])
    #expect(grouped.menuBarGrouping.rankedUnits(configuration: grouped, priority: [.ssd, .gpu, .memory, .cpu]).prefix(2) == [.memorySSD, .cpuGPU])
    let split = MonitorConfiguration(order: order, menuBarGrouping: MenuBarGrouping(cpuGPU: true, memorySSD: false))
    #expect(split.menuBarGrouping.units(metrics: split.visible).prefix(3) == [.cpuGPU, .metric(.memory), .metric(.ssd)])
}

@Test func pairedMenuBarUnitsRespectPlacementAndSurviveOneDisabledMember() {
    let groups = MenuBarGrouping(cpuGPU: true, memorySSD: true)
    #expect(groups.units(metrics: [.network, .gpu, .memory, .cpu, .ssd, .disk]) ==
            [.metric(.network), .memorySSD, .cpuGPU, .metric(.disk)])
    #expect(groups.units(metrics: [.gpu, .ssd]) == [.metric(.gpu), .metric(.ssd)])
    #expect(MenuBarGrouping(cpuGPU: false, memorySSD: false).units(metrics: [.cpu, .gpu, .memory, .ssd]).count == 4)
    #expect(groups.units(metrics: []) == [])
}

@Test func groupingKeepsPairsTogetherWhenSpaceIsLimitedWithoutChangingMonitoring() {
    let config = MonitorConfiguration(enabled: [.cpu, .gpu, .memory, .ssd, .network],
        order: [.cpu, .memory, .ssd, .gpu, .network], menuBarGrouping: MenuBarGrouping(cpuGPU: true))
    let priority: [Metric] = [.ssd, .network, .gpu, .cpu, .memory]
    #expect(config.menuBarGrouping.rankedUnits(configuration: config, priority: priority) ==
            [.memorySSD, .metric(.network), .cpuGPU])
    #expect(MenuBarDensity.minimal.metrics(configuration: config, priority: priority) == [.memory, .ssd])
    #expect(MenuBarDensity.compact.metrics(configuration: config, priority: priority) == [.memory, .ssd, .network])
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: priority, automaticLimit: 3) == config.visible)
    #expect(config.enabled.count == 5)
}

@Test func legacyDiskCapacityAlertMigratesToSSDAndLongPollingCanConfirm() throws {
    let oldRule = AlertRule(metric: .disk, enabled: true, threshold: 20, duration: 10)
    let config = AlertConfiguration(rules: [oldRule]).normalized
    #expect(config.rule(for: .ssd).enabled && config.rule(for: .ssd).threshold == 20)
    #expect(!config.hasEnabledRules(monitored: [.disk]))
    var engine = AlertEngine()
    func reading(_ time: Double) -> MetricReading {
        MetricReading(metric: .ssd, date: Date(timeIntervalSince1970: time),
            value: .storage(DiskCapacityReading(name: "Data", total: 1e12, available: 10e9,
                sampledAt: Date(timeIntervalSince1970: time), uptime: time, pollingInterval: 600)))
    }
    #expect(engine.evaluate([reading(0)], configuration: config, monitored: [.ssd], uptime: 0, interval: 2).isEmpty)
    #expect(engine.evaluate([reading(0)], configuration: config, monitored: [.ssd], uptime: 10, interval: 2).isEmpty)
    #expect(engine.evaluate([reading(600)], configuration: config, monitored: [.ssd], uptime: 600, interval: 2).count == 1)
    let oldEvent = try JSONDecoder().decode(AlertEvent.self, from: Data(#"{"id":"A5A85460-746D-4BCE-A68F-047422D47973","rule":{"id":"disk","enabled":true,"threshold":20,"duration":10},"firstDetected":0,"observedAt":0,"value":10}"#.utf8))
    var restored = AlertEngine(restored: [oldEvent])
    #expect(restored.active.first?.metric == .ssd && restored.active.first?.id == oldEvent.id)
    #expect(restored.evaluate([reading(600)], configuration: config, monitored: [.ssd], uptime: 600, interval: 2).isEmpty)
}
