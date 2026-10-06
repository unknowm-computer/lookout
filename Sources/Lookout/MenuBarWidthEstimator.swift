import AppKit
import LookoutCore

/// Renderer widths are fixed across samples. Only recalculate after layout or alert settings change.
@MainActor final class MenuBarWidthEstimator {
    private struct Key: Equatable {
        let configuration: MonitorConfiguration
        let priority: [Metric]
        let mode: MenuBarDisplayMode
        let alertMetrics: Set<Metric>
        let padding: Double
        let gap: Double
        let values: MenuBarValuePreferences
    }
    private var key: Key?
    private var cached: [Double] = []

    func widths(settings: SettingsStore, measurement: MenuBarGeometry.Measurement) -> [Double] {
        let ranked = settings.configuration.menuBarGrouping.rankedUnits(
            configuration: settings.configuration, priority: settings.menuBarPriority)
        let alerts = Set(Metric.allCases.filter { settings.alerts.hasEnabledRules(monitored: [$0]) })
        let nextKey = Key(configuration: settings.configuration, priority: settings.menuBarPriority,
                          mode: settings.menuBarDisplayMode, alertMetrics: alerts,
                          padding: measurement.padding, gap: measurement.gap, values: settings.menuBarValues)
        if key == nextKey { return cached }
        key = nextKey
        guard !ranked.isEmpty else { cached = []; return cached }
        var previousWidth = 0.0
        cached = (1...ranked.count).map { count in
            let metrics = MenuBarDensity.automatic.metrics(configuration: settings.configuration,
                priority: settings.menuBarPriority, automaticLimit: count)
            let total: Double
            if settings.menuBarDisplayMode == .individual {
                let units = settings.configuration.menuBarGrouping.units(metrics: metrics)
                total = units.reduce(0) { sum, unit in
                    let image = MenuBarRenderer.image(metrics: unit.metrics, readings: [:],
                        showAlertSlot: !alerts.isDisjoint(with: unit.metrics), compact: true,
                        grouping: settings.configuration.menuBarGrouping, values: settings.menuBarValues)
                    return sum + image.size.width + measurement.padding
                } + Double(max(0, count - 1)) * measurement.gap
            } else {
                total = MenuBarRenderer.image(metrics: metrics, readings: [:],
                    showAlertSlot: !alerts.isDisjoint(with: settings.configuration.enabled),
                    grouping: settings.configuration.menuBarGrouping, values: settings.menuBarValues).size.width
                    + measurement.padding
            }
            defer { previousWidth = total }
            return total - previousWidth
        }
        return cached
    }
}
