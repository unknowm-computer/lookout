import Foundation
import LookoutCore
import Testing

@Test func customGroupsMigrateLegacyChoicesAndPreserveExplicitUngrouping() throws {
    let decoder = JSONDecoder()
    for cpu in [false, true] {
        for ram in [false, true] {
            let legacy = Data("{\"cpuGPU\":\(cpu),\"memorySSD\":\(ram)}".utf8)
            let groups = try decoder.decode(MenuBarGrouping.self, from: legacy)
            #expect(groups == MenuBarGrouping(cpuGPU: cpu, memorySSD: ram))
            #expect(try decoder.decode(MenuBarGrouping.self, from: JSONEncoder().encode(groups)) == groups)
        }
    }
    let empty = try decoder.decode(MenuBarGrouping.self, from: Data(#"{"pairs":[],"cpuGPU":true,"memorySSD":true}"#.utf8))
    #expect(empty.pairs.isEmpty)
    let custom = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .memory), MenuBarPair(.gpu, .power)])
    #expect(try decoder.decode(MenuBarGrouping.self, from: JSONEncoder().encode(custom)) == custom)
}

@Test func customGroupsRejectDuplicateAndRateMetricsAndNeverContainThreeItems() {
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .cpu), MenuBarPair(.network, .disk),
        MenuBarPair(.cpu, .memory), MenuBarPair(.memory, .ssd), MenuBarPair(.gpu, .power)])
    #expect(groups.pairs == [MenuBarPair(.cpu, .memory), MenuBarPair(.gpu, .power)])
    #expect(groups.pairing(.network, with: .cpu) == groups)
    #expect(groups.pairing(.cpu, with: .cpu) == groups)
    let regrouped = groups.pairing(.cpu, with: .power)
    #expect(regrouped.pairs == [MenuBarPair(.cpu, .power)])
    #expect(regrouped.units(metrics: [.cpu, .memory, .gpu, .power, .ssd]) ==
            [.pair(.cpu, .power), .metric(.memory), .metric(.gpu), .metric(.ssd)])
    #expect(groups.pairing(.memory, with: .cpu).pairs.first == MenuBarPair(.memory, .cpu))
    #expect(groups.removing(.cpu).pairs == [MenuBarPair(.gpu, .power)])
}

@Test func arbitraryGroupsKeepPlacementPriorityAndDisabledMembersIndependent() {
    let groups = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .memory), MenuBarPair(.gpu, .power)])
    let config = MonitorConfiguration(order: [.network, .memory, .ssd, .power, .disk, .cpu, .gpu], menuBarGrouping: groups)
    #expect(groups.units(metrics: config.visible) == [.metric(.network), .metric(.ssd), .metric(.disk),
        .pair(.cpu, .memory), .pair(.gpu, .power)])
    #expect(MenuBarDensity.minimal.metrics(configuration: config, priority: [.power]) == [.power, .gpu])
    #expect(groups.units(metrics: [.ssd, .memory, .gpu]) == [.metric(.ssd), .metric(.memory), .metric(.gpu)])
    #expect(groups.pairs.count == 2)
}

@Test func allEligiblePairOrdersRoundTripAndKeepTheirRows() throws {
    for upper in MenuBarGrouping.eligible {
        for lower in MenuBarGrouping.eligible where upper != lower {
            let group = MenuBarGrouping(pairs: [MenuBarPair(upper, lower)])
            let config = MonitorConfiguration(menuBarGrouping: group)
            let restored = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: config)))
            #expect(restored.configuration == config)
            #expect(group.units(metrics: [lower, upper]) == [.pair(upper, lower)])
            #expect(group.swapping(upper).units(metrics: [upper, lower]) == [.pair(lower, upper)])
        }
    }
}
