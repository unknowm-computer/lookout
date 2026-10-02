import LookoutCore
import Testing

@Test func menuBarPrioritySelectsItemsWithoutReorderingTheirPlacement() {
    let config = MonitorConfiguration(enabled: [.cpu, .memory, .network, .gpu],
                                      order: [.cpu, .memory, .gpu, .network])
    let priority: [Metric] = [.disk, .network, .gpu, .cpu, .memory]
    #expect(MenuBarDensity.compact.metrics(configuration: config, priority: priority) == [.gpu, .network])
    #expect(MenuBarDensity.minimal.metrics(configuration: config, priority: priority) == [.network])
    #expect(MenuBarDensity.normal.metrics(configuration: config, priority: priority) == config.visible)
    #expect(config.enabled == [.cpu, .memory, .network, .gpu])
    #expect(config.visible == [.cpu, .memory, .gpu, .network])
}

@Test func automaticStartsWithAllItemsThenUsesMeasuredLimitAndRecovers() {
    let config = MonitorConfiguration(enabled: [.cpu, .memory, .network], order: [.cpu, .memory, .network])
    let priority: [Metric] = [.network, .cpu, .memory]
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: priority) == config.visible)
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: priority, automaticLimit: 2) == [.cpu, .network])
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: priority, automaticLimit: 1) == [.network])
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: priority, automaticLimit: 3) == config.visible)
    #expect(MenuBarDensity.normal.metrics(configuration: config, priority: priority, automaticLimit: 1) == config.visible)
}

@Test func menuBarSelectionHandlesEmptyShortAndInvalidPriorityLists() {
    for mode in MenuBarDensity.allCases {
        #expect(mode.metrics(configuration: MonitorConfiguration(enabled: []), priority: []) == [])
        #expect(mode.metrics(configuration: MonitorConfiguration(enabled: [.power]), priority: []) == [.power])
    }
    let normalized = MenuBarDensity.normalizedPriority([.gpu, .gpu, .cpu])
    #expect(normalized.prefix(2) == [.gpu, .cpu])
    #expect(Set(normalized) == Set(Metric.allCases))
    #expect(normalized.count == Metric.allCases.count)
    let config = MonitorConfiguration(enabled: [.cpu, .network], order: [.cpu, .network])
    #expect(MenuBarDensity.automatic.metrics(configuration: config, priority: [.network], automaticLimit: 0) == [.network])
}

@Test func spaceBudgetKeepsEveryCountFromSixToOneAndRestoresAtExactFit() {
    let widths = [73.0, 73.0, 73.0, 76.0, 78.0, 89.0]
    var total = widths.reduce(0, +)
    for count in stride(from: 6, through: 1, by: -1) {
        #expect(MenuBarSpacePolicy.limit(widths: widths, available: total) == count)
        if count > 1 {
            #expect(MenuBarSpacePolicy.limit(widths: widths, available: total - 0.5) == count - 1)
        }
        total -= widths[count - 1]
    }
    #expect(MenuBarSpacePolicy.limit(widths: widths, available: 462) == 6)
    #expect(MenuBarSpacePolicy.limit(widths: widths, available: -10) == 1)
}

@Test func displayBudgetUsesTheSelectedScreenRatherThanTheSmallestConnectedScreen() {
    // Both displays share a status-item right inset; the external display has room for all six.
    let external = MenuBarSpacePolicy.availableWidth(screenMinX: -426, screenMaxX: 2582,
                                                      safeMinX: -426, rightInset: 804)
    let builtIn = MenuBarSpacePolicy.availableWidth(screenMinX: 0, screenMaxX: 2056,
                                                     safeMinX: 1138, rightInset: 804)
    #expect(external == 2204)
    #expect(builtIn == 114)
    let widths = [73.0, 73.0, 73.0, 76.0, 78.0, 89.0]
    #expect(MenuBarSpacePolicy.limit(widths: widths, available: external!) == 6)
    #expect(MenuBarSpacePolicy.limit(widths: widths, available: builtIn!) == 1)
    #expect(MenuBarSpacePolicy.availableWidth(screenMinX: 0, screenMaxX: 100, safeMinX: 101, rightInset: 10) == nil)
}

@Test func expansionWaitsForStableTimeWithoutRequiringExtraWidth() {
    var gate = MenuBarExpansionGate()
    #expect(gate.resolve(target: 6, current: 2, uptime: 10) == 2)
    #expect(gate.resolve(target: 6, current: 2, uptime: 10.9) == 2)
    #expect(gate.resolve(target: 6, current: 2, uptime: 11) == 6)
    #expect(gate.resolve(target: 5, current: 6, uptime: 11.1) == 5)
    #expect(gate.resolve(target: 6, current: 5, uptime: 12) == 5)
    #expect(gate.resolve(target: 4, current: 5, uptime: 12.5) == 4)
    #expect(gate.resolve(target: 6, current: 4, uptime: 13) == 4)
    #expect(gate.resolve(target: 6, current: 4, uptime: 14) == 6)
}

@Test func unknownOrInvalidGeometryDoesNotInventAFittingCount() {
    #expect(MenuBarSpacePolicy.limit(widths: [], available: 100) == nil)
    #expect(MenuBarSpacePolicy.limit(widths: [70, .nan], available: 100) == nil)
    #expect(MenuBarSpacePolicy.limit(widths: [70], available: .infinity) == nil)
    #expect(MenuBarSpacePolicy.limit(widths: [70, 0], available: 100) == nil)
}
