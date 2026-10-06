import AppKit
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func arbitraryGroupsPersistWithoutChangingMonitoringOrAlerts() throws {
    let name = "LookoutTests.customGroups.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let config = store.configuration, alerts = store.alerts, charts = store.charts
    let priority = store.menuBarPriority, values = store.menuBarValues
    let grouping = MenuBarGrouping(pairs: [MenuBarPair(.cpu, .memory), MenuBarPair(.gpu, .power)])
    store.setMenuBarGrouping(grouping)
    let restored = SettingsStore(defaults: defaults)
    var expected = config; expected.menuBarGrouping = grouping
    #expect(restored.configuration == expected)
    #expect(restored.alerts == alerts && restored.charts == charts)
    #expect(restored.menuBarPriority == priority && restored.menuBarValues == values)
    let intel = SettingsStore(defaults: defaults, capabilities: MonitoringCapabilities(supportsProcessEnergy: false))
    #expect(intel.configuration.menuBarGrouping == grouping)
    #expect(!intel.configuration.enabled.contains(.power))
    #expect(intel.configuration.menuBarGrouping.units(metrics: intel.configuration.visible).contains(.metric(.gpu)))
}

@Test @MainActor func pairingDragOnlyPreviewsUntilReleaseAndInvalidTargetsDoNothing() {
    let original = MenuBarGrouping(cpuGPU: true, memorySSD: true)
    let frames: [Metric: CGRect] = [.cpu: CGRect(x: 0, y: 0, width: 70, height: 24),
        .gpu: CGRect(x: 0, y: 28, width: 70, height: 24),
        .memory: CGRect(x: 80, y: 0, width: 70, height: 24),
        .ssd: CGRect(x: 80, y: 28, width: 70, height: 24),
        .power: CGRect(x: 160, y: 0, width: 70, height: 24)]
    var drag = MenuBarPairingSession(source: .cpu, original: original, frames: frames,
        detachFrame: CGRect(x: 0, y: 70, width: 230, height: 28), boardSize: CGSize(width: 230, height: 98),
        supported: Set(MenuBarGrouping.eligible))
    drag.update(location: CGPoint(x: 100, y: 12), translation: CGSize(width: 80, height: 0))
    #expect(drag.target == .memory && drag.preview?.pairs == [MenuBarPair(.cpu, .memory)])
    #expect(drag.original == original && original.pairs.count == 2)
    drag.update(location: CGPoint(x: 30, y: 40), translation: CGSize(width: 0, height: 28))
    #expect(drag.preview?.pairs.first == MenuBarPair(.gpu, .cpu))
    drag.update(location: CGPoint(x: 30, y: 84), translation: CGSize(width: 0, height: 72))
    #expect(drag.detaching && drag.preview?.pairs == [MenuBarPair(.memory, .ssd)])
    drag.update(location: CGPoint(x: 30, y: 12), translation: .zero)
    #expect(drag.preview == nil && drag.target == nil && !drag.detaching)
    drag.update(location: CGPoint(x: -10, y: 12), translation: CGSize(width: -40, height: 0))
    #expect(drag.detaching)
    var restricted = MenuBarPairingSession(source: .cpu, original: original, frames: frames,
        detachFrame: .zero, boardSize: CGSize(width: 230, height: 98), supported: [.cpu, .gpu])
    restricted.update(location: CGPoint(x: 180, y: 12), translation: CGSize(width: 160, height: 0))
    #expect(restricted.preview == nil)
}

@Test @MainActor func arbitraryPairRenderingKeepsMarkersWarningsWattsAndFixedWidths() throws {
    let readings: [Metric: MetricReading] = [.power: MetricReading(metric: .power, date: Date(),
        value: .power(PowerReading(watts: 2.5, processes: [], measuredCount: 1, readableCount: 1, totalCount: 1)))]
    for upper in MenuBarGrouping.eligible {
        for lower in MenuBarGrouping.eligible where upper != lower {
            let group = MenuBarGrouping(pairs: [MenuBarPair(upper, lower)])
            let empty = MenuBarRenderer.presentation(metrics: [lower, upper], readings: [:], grouping: group)
            let current = MenuBarRenderer.presentation(metrics: [lower, upper], readings: readings,
                grouping: group, alerting: [upper, lower])
            #expect(empty.image.size == current.image.size)
            #expect(current.highlightedValues.map(\.metric) == [upper, lower])
            #expect(current.highlightedValues[0].frame.minY == 11 && current.highlightedValues[1].frame.minY == 0)
            if [upper, lower].contains(.power) {
                #expect(current.highlightedValues.first { $0.metric == .power }?.text == "2.5 W")
            }
            #expect((current.pressureFrame != nil) == [upper, lower].contains(.memory))
            #expect((current.storageFrame != nil) == [upper, lower].contains(.ssd))
            if let frame = current.pressureFrame { #expect(frame.minY == (upper == .memory ? 14 : 3)) }
            if let frame = current.storageFrame { #expect(frame.minY == (upper == .ssd ? 14 : 3)) }
            let percent = MenuBarRenderer.presentation(metrics: [lower, upper], readings: [:], grouping: group,
                values: MenuBarValuePreferences(storage: .percentage))
            #expect(percent.storageFrame == nil)
            let usedCapacity = MenuBarRenderer.presentation(metrics: [lower, upper], readings: [:], grouping: group,
                values: MenuBarValuePreferences(storage: .used))
            #expect(usedCapacity.storageFrame == nil)
            #expect(usedCapacity.pressureFrame?.minY == current.pressureFrame?.minY)
            let remainingValues = MenuBarValuePreferences(storage: .availablePercentage)
            let remaining = MenuBarRenderer.presentation(metrics: [lower, upper], readings: [:], grouping: group,
                values: remainingValues)
            let remainingAlert = MenuBarRenderer.presentation(metrics: [lower, upper], readings: readings,
                grouping: group, values: remainingValues, alerting: [upper, lower])
            #expect(remaining.image.size == remainingAlert.image.size)
            #expect((remaining.storageFrame != nil) == [upper, lower].contains(.ssd))
            #expect(remaining.storageFrame?.minY == current.storageFrame?.minY)
            #expect(remaining.storageFrame?.size == current.storageFrame?.size)
            #expect(remaining.pressureFrame?.minY == current.pressureFrame?.minY)
        }
    }
}

@Test @MainActor func groupingDropAcceptsWholeCardButKeepsGapAndOriginalPositionUnchanged() {
    let original = MenuBarGrouping(pairs: [])
    var drag = MenuBarPairingSession(source: .cpu, original: original,
        frames: [.cpu: CGRect(x: 10, y: 30, width: 60, height: 24), .memory: CGRect(x: 90, y: 30, width: 60, height: 24)],
        detachFrame: CGRect(x: 0, y: 98, width: 160, height: 28), boardSize: CGSize(width: 160, height: 126),
        supported: [.cpu, .memory], targetFrames: [.cpu: CGRect(x: 0, y: 0, width: 75, height: 90),
                                                .memory: CGRect(x: 83, y: 0, width: 75, height: 90)])
    drag.update(location: CGPoint(x: 150, y: 80), translation: CGSize(width: 120, height: 38))
    #expect(drag.target == .memory && drag.preview?.pairs == [MenuBarPair(.cpu, .memory)])
    drag.update(location: CGPoint(x: 79, y: 80), translation: CGSize(width: 49, height: 38))
    #expect(drag.preview == nil)
    drag.update(location: CGPoint(x: 10, y: 80), translation: CGSize(width: -20, height: 38))
    #expect(drag.preview == nil)
}
