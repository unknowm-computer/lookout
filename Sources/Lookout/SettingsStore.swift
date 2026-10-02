import Combine
import Foundation
import LookoutCore

@MainActor final class SettingsStore: ObservableObject {
    @Published private(set) var configuration: MonitorConfiguration
    @Published private(set) var alerts: AlertConfiguration
    @Published private(set) var charts: ChartPreferences
    @Published private(set) var menuBarDisplayMode: MenuBarDisplayMode
    @Published private(set) var menuBarDensity: MenuBarDensity
    @Published private(set) var menuBarPriority: [Metric]
    private let defaults: UserDefaults
    let capabilities: MonitoringCapabilities
    static let key = "monitorSettings.v1"
    init(defaults: UserDefaults = .standard, capabilities: MonitoringCapabilities = .current) {
        self.defaults = defaults
        self.capabilities = capabilities
        menuBarDisplayMode = defaults.string(forKey: "menuBarDisplayMode.v1")
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .individual
        menuBarDensity = defaults.string(forKey: "menuBarDensity.v1")
            .flatMap(MenuBarDensity.init(rawValue:)) ?? .automatic
        let storedConfiguration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SettingsRecord.self, from: $0) }?.configuration ?? MonitorConfiguration()
        configuration = capabilities.applying(to: storedConfiguration)
        let savedPriority = defaults.stringArray(forKey: "menuBarPriority.v1")
        let priority = MenuBarDensity.normalizedPriority(
            savedPriority?.compactMap(Metric.init(rawValue:)) ?? storedConfiguration.order)
        menuBarPriority = priority
        // Freeze the migrated baseline so later placement changes do not change priority on relaunch.
        if savedPriority == nil { defaults.set(priority.map(\.rawValue), forKey: "menuBarPriority.v1") }
        alerts = defaults.data(forKey: "alertSettings.v1")
            .flatMap { try? JSONDecoder().decode(AlertConfiguration.self, from: $0) }?.normalized ?? AlertConfiguration()
        charts = defaults.data(forKey: "chartSettings.v1")
            .flatMap { try? JSONDecoder().decode(ChartPreferences.self, from: $0) }?.normalized ?? ChartPreferences()
    }
    func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode) {
        guard mode != menuBarDisplayMode else { return }
        defaults.set(mode.rawValue, forKey: "menuBarDisplayMode.v1")
        menuBarDisplayMode = mode
    }
    func setMenuBarDensity(_ density: MenuBarDensity) {
        guard density != menuBarDensity else { return }
        defaults.set(density.rawValue, forKey: "menuBarDensity.v1")
        menuBarDensity = density
    }
    func moveMenuBarPriority(_ metric: Metric, to target: Metric) {
        let next = MetricOrdering.moving(metric, to: target, in: menuBarPriority)
        guard next != menuBarPriority else { return }
        defaults.set(next.map(\.rawValue), forKey: "menuBarPriority.v1")
        menuBarPriority = next
    }
    func setChartStyle(_ style: ChartStyle, for metric: Metric) {
        var next = charts; next.set(style, for: metric)
        guard next != charts, let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: "chartSettings.v1"); charts = next
    }
    func updateAlert(_ metric: Metric, _ change: (inout AlertRule) -> Void) {
        var next = alerts
        guard let index = next.rules.firstIndex(where: { $0.metric == metric }) else { return }
        change(&next.rules[index]); saveAlerts(next)
    }
    func setAlertSound(_ sound: Bool) {
        var next = alerts; next.sound = sound; saveAlerts(next)
    }
    private func saveAlerts(_ value: AlertConfiguration) {
        let value = value.normalized
        guard value != alerts, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "alertSettings.v1"); alerts = value
    }
    func restoredAlerts() -> [AlertEvent] {
        defaults.data(forKey: "activeAlerts.v1").flatMap { try? JSONDecoder().decode([AlertEvent].self, from: $0) } ?? []
    }
    func saveActiveAlerts(_ events: [AlertEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: "activeAlerts.v1")
    }
    func setEnabled(_ metric: Metric, _ enabled: Bool) {
        guard !enabled || capabilities.supports(metric) else { return }
        var next = configuration
        if enabled { next.enabled.insert(metric) } else { next.enabled.remove(metric) }
        update(next)
    }
    func setInterval(_ interval: Int) {
        var next = configuration; next.interval = [1, 2, 5].contains(interval) ? interval : 2; update(next)
    }
    func setInterface(_ interface: String?) {
        var next = configuration; next.interface = interface; update(next)
    }
    func move(_ metric: Metric, to target: Metric) {
        var next = configuration
        next.order = MetricOrdering.moving(metric, to: target, in: next.order)
        guard next != configuration else { return }
        update(next)
    }
    private func update(_ value: MonitorConfiguration) {
        let value = capabilities.applying(to: value)
        guard let data = try? JSONEncoder().encode(SettingsRecord(configuration: value)) else { return }
        defaults.set(data, forKey: Self.key)
        configuration = value
    }
}

@MainActor final class DefaultsSpacingPersistence: SpacingPersistence {
    private let defaults: UserDefaults
    private let key = "menuSpacingTransaction.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> SpacingTransaction? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(SpacingTransaction.self, from: data)
    }
    func save(_ transaction: SpacingTransaction?) throws {
        if let transaction {
            defaults.set(try JSONEncoder().encode(transaction), forKey: key)
        } else { defaults.removeObject(forKey: key) }
        guard defaults.synchronize() else { throw SpacingError.storage }
    }
}
