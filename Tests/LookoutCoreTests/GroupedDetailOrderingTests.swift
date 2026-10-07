import LookoutCore
import Testing

@Test func groupedDetailsFollowUpperPlacementWithoutChangingMonitoringOrSpacePriority() {
    let order: [Metric] = [.cpu, .memory, .ssd, .network, .gpu, .disk, .power]
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.gpu, .cpu), MenuBarPair(.power, .memory)])
    let config = MonitorConfiguration(order: order, menuBarGrouping: groups)
    #expect(config.detailMetrics == [.ssd, .network, .gpu, .cpu, .disk, .power, .memory])
    #expect(config.visible == order)
    #expect(config.menuBarGrouping.rankedUnits(configuration: config, priority: [.memory, .cpu]).prefix(2)
            == [.pair(.power, .memory), .pair(.gpu, .cpu)])
    #expect(MenuBarDensity.minimal.metrics(configuration: config, priority: [.memory]) == [.memory, .power])

    var changed = config
    changed.menuBarGrouping = groups.swapping(.gpu)
    #expect(changed.detailMetrics == [.cpu, .gpu, .ssd, .network, .disk, .power, .memory])
    changed.menuBarGrouping = MenuBarGrouping(pairs: [])
    #expect(changed.detailMetrics == order)
}

@Test func groupedDetailsKeepDisabledPartnersSingleAndReturnGroupsWhenReenabled() {
    let order: [Metric] = [.cpu, .network, .memory, .gpu, .disk, .ssd, .power]
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.gpu, .cpu), MenuBarPair(.ssd, .memory)])
    var config = MonitorConfiguration(order: order, menuBarGrouping: groups)
    #expect(config.detailMetrics == [.network, .gpu, .cpu, .disk, .ssd, .memory, .power])
    config.enabled.remove(.gpu)
    #expect(config.detailMetrics == [.cpu, .network, .disk, .ssd, .memory, .power])
    config.enabled.remove(.memory)
    #expect(config.detailMetrics == [.cpu, .network, .disk, .ssd, .power])
    config.enabled.insert(.gpu)
    config.enabled.insert(.memory)
    #expect(config.detailMetrics == [.network, .gpu, .cpu, .disk, .ssd, .memory, .power])
    config.enabled = []
    #expect(config.detailMetrics.isEmpty)
    #expect(config.menuBarGrouping == groups)
}
