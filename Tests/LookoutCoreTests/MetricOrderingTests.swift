import LookoutCore
import Testing

@Test func draggingAcrossSeveralRowsShiftsInterveningMetrics() {
    let order: [Metric] = [.cpu, .memory, .gpu, .network, .disk, .power]
    #expect(MetricOrdering.moving(.cpu, to: .network, in: order) == [.memory, .gpu, .network, .cpu, .disk, .power])
    #expect(MetricOrdering.moving(.power, to: .memory, in: order) == [.cpu, .power, .memory, .gpu, .network, .disk])
    for source in order {
        for target in order {
            let moved = MetricOrdering.moving(source, to: target, in: order)
            #expect(moved.count == order.count)
            #expect(Set(moved) == Set(order))
        }
    }
    #expect(MetricOrdering.moving(.cpu, to: .cpu, in: order) == order)
    #expect(MetricOrdering.moving(.cpu, to: .gpu, in: [.cpu, .memory]) == [.cpu, .memory])
    #expect(MetricOrdering.moving(.gpu, to: .cpu, in: [.cpu, .memory]) == [.cpu, .memory])
}

@Test func draggedPrioritySelectsCompactItemsWhilePlacementAndMonitoringStayIntact() {
    let config = MonitorConfiguration(enabled: [.cpu, .memory, .network, .gpu],
                                      order: [.cpu, .memory, .gpu, .network], interval: 5, interface: "en0")
    let priority = MetricOrdering.moving(.network, to: .cpu, in: config.order)
    #expect(MenuBarDensity.compact.metrics(configuration: config, priority: priority) == [.cpu, .network])
    #expect(MenuBarDensity.normal.metrics(configuration: config, priority: priority) == config.visible)
    #expect(config.visible == [.cpu, .memory, .gpu, .network])
    #expect(config.interval == 5)
    #expect(config.interface == "en0")
    #expect(SettingsRecord(configuration: config).configuration == config)
}
