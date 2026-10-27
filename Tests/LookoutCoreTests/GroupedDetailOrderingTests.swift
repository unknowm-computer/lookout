import LookoutCore
import Testing

@Test func combinedDetailsFollowMonitoringOrderRegardlessOfMenuBarGroups() {
    let order: [Metric] = [.cpu, .memory, .ssd, .network, .gpu, .disk, .power]
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.gpu, .cpu), MenuBarPair(.power, .memory)])
    let config = MonitorConfiguration(enabled: Set(order), order: order, menuBarGrouping: groups)
    #expect(config.detailMetrics() == order)
    #expect(config.detailMetrics(selected: [.gpu, .cpu]) == [.gpu, .cpu])
    #expect(config.visible == order)
    #expect(config.menuBarGrouping.rankedUnits(configuration: config, priority: [.memory, .cpu]).prefix(2)
            == [.pair(.power, .memory), .pair(.gpu, .cpu)])
    #expect(MenuBarDensity.minimal.metrics(configuration: config, priority: [.memory]) == [.memory, .power])

    var changed = config
    changed.menuBarGrouping = groups.swapping(.gpu)
    #expect(changed.detailMetrics() == order)
    #expect(changed.detailMetrics(selected: [.cpu, .gpu]) == [.cpu, .gpu])
    changed.menuBarGrouping = MenuBarGrouping(pairs: [])
    #expect(changed.detailMetrics() == order)
}

@Test func groupedDetailsKeepDisabledPartnersSingleAndReturnGroupsWhenReenabled() {
    let order: [Metric] = [.cpu, .network, .memory, .gpu, .disk, .ssd, .power]
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.gpu, .cpu), MenuBarPair(.ssd, .memory)])
    var config = MonitorConfiguration(enabled: Set(order), order: order, menuBarGrouping: groups)
    #expect(config.detailMetrics() == order)
    #expect(config.detailMetrics(selected: [.gpu, .cpu]) == [.gpu, .cpu])
    config.enabled.remove(.gpu)
    #expect(config.detailMetrics() == [.cpu, .network, .memory, .disk, .ssd, .power])
    #expect(config.detailMetrics(selected: [.gpu, .cpu]) == [.cpu])
    config.enabled.remove(.memory)
    #expect(config.detailMetrics() == [.cpu, .network, .disk, .ssd, .power])
    #expect(config.detailMetrics(selected: [.ssd, .memory]) == [.ssd])
    config.enabled.insert(.gpu)
    config.enabled.insert(.memory)
    #expect(config.detailMetrics() == order)
    #expect(config.detailMetrics(selected: [.gpu, .cpu]) == [.gpu, .cpu])
    config.enabled = []
    #expect(config.detailMetrics().isEmpty)
    #expect(config.detailMetrics(selected: [.gpu, .cpu]).isEmpty)
    #expect(config.menuBarGrouping == groups)
}

@Test func combinedCoolingAndEnergyDetailsTrackPlacementChangesWithoutChangingTheirGroup() {
    let grouping = MenuBarGrouping(pairs: [MenuBarPair(.power, .cooling)])
    var config = MonitorConfiguration(enabled: [.cooling, .power], order: [.cooling, .power], menuBarGrouping: grouping)
    #expect(config.detailMetrics() == [.cooling, .power])
    #expect(config.detailMetrics(selected: [.power, .cooling]) == [.power, .cooling])
    config.order = MetricOrdering.moving(.power, to: .cooling, in: config.order)
    #expect(config.detailMetrics() == [.power, .cooling])
    #expect(config.menuBarGrouping == grouping)
}
