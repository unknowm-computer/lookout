import AppKit
import Combine
import LookoutCore

@MainActor final class MonitoringCoordinator: ObservableObject {
    @Published private(set) var readings: [Metric: MetricReading] = [:]
    @Published private(set) var histories: [Metric: HistoryBuffer] = [:]
    @Published private(set) var interfaces: [String] = []
    @Published private(set) var lastUpdate = Date()
    @Published private(set) var activeAlerts: [AlertEvent] = []
    let settings: SettingsStore
    let processDetails: ProcessDetailsStore
    let notifications = NotificationService()
    private let sampler = MetricSampler()
    private var alertEngine: AlertEngine
    private var savedAlertIDs: Set<UUID>
    private var task: Task<Void, Never>?
    private var generation: Int = 0
    private var sleeping = false
    private var subscriptions: Set<AnyCancellable> = []
    private var previousConfig: MonitorConfiguration

    init(settings: SettingsStore) {
        self.settings = settings; previousConfig = settings.configuration
        processDetails = ProcessDetailsStore(configuration: settings.configuration)
        let restored = settings.restoredAlerts()
        alertEngine = AlertEngine(restored: restored)
        savedAlertIDs = Set(restored.map(\.id))
        settings.$configuration.dropFirst().sink { [weak self] config in
            self?.reconfigure(config)
        }.store(in: &subscriptions)
        settings.$alerts.dropFirst().sink { [weak self] configuration in
            guard let self else { return }
            self.alertEngine.configure(configuration, monitored: self.settings.configuration.enabled)
            self.publishAlerts(sound: configuration.sound)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.notifications.refreshAuthorization() }
        }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        }.store(in: &subscriptions)
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }.store(in: &subscriptions)
        alertEngine.configure(settings.alerts, monitored: settings.configuration.enabled)
        publishAlerts()
        restart()
    }
    private func reconfigure(_ config: MonitorConfiguration) {
        processDetails.configure(config)
        let enabledChanged = config.enabled != previousConfig.enabled
        for metric in Metric.allCases where !config.enabled.contains(metric) {
            readings.removeValue(forKey: metric); histories.removeValue(forKey: metric)
        }
        if config.interface != previousConfig.interface {
            readings.removeValue(forKey: .network)
            histories.removeValue(forKey: .network)
        }
        for metric in [Metric.network, .disk] where config.rateBasis(for: metric) != previousConfig.rateBasis(for: metric) {
            readings.removeValue(forKey: metric); histories.removeValue(forKey: metric)
        }
        previousConfig = config
        alertEngine.configure(settings.alerts, monitored: config.enabled)
        publishAlerts()
        restart(configuration: config, reset: enabledChanged)
    }
    private func restart(configuration: MonitorConfiguration? = nil, reset: Bool = false) {
        task?.cancel(); generation += 1
        let config = configuration ?? settings.configuration, token = generation
        guard !sleeping else { return }
        task = Task { [weak self, sampler] in
            if reset { await sampler.reset() }
            // collect with an empty configuration still resets disabled collectors without reading APIs.
            while !Task.isCancelled {
                let results = await sampler.collect(config)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                for reading in results {
                    self.readings[reading.metric] = reading
                    if reading.metric != .ssd {
                        self.histories[reading.metric, default: HistoryBuffer()].append(reading, interval: config.interval)
                    }
                }
                self.alertEngine.evaluate(results, configuration: self.settings.alerts, monitored: config.enabled,
                                          uptime: ProcessInfo.processInfo.systemUptime, interval: config.interval)
                self.publishAlerts()
                self.lastUpdate = Date()
                if config.enabled.isEmpty { return }
                let interval = config.enabled == [.ssd] ? config.storageInterval : config.interval
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }
    private func sleep() {
        processDetails.suspend()
        sleeping = true; task?.cancel(); generation += 1
        alertEngine.breakContinuity()
        publishAlerts()
        for metric in histories.keys { histories[metric]?.breakContinuity() }
    }
    private func wake() {
        processDetails.resume()
        sleeping = false; readings.removeAll()
        for metric in histories.keys { histories[metric]?.prune(at: Date()) }
        restart(reset: true)
    }
    private func publishAlerts(sound: Bool? = nil) {
        let events = alertEngine.active
        if events != activeAlerts { activeAlerts = events }
        let ids = Set(events.map(\.id))
        if ids != savedAlertIDs { settings.saveActiveAlerts(events); savedAlertIDs = ids }
        notifications.synchronize(active: events, sound: sound ?? settings.alerts.sound, eligible: alertEngine.notificationEligibleIDs)
    }
    func refreshInterfaces() {
        Task {
            let names = await Task.detached(priority: .utility) { (try? SystemMetrics.interfaces().map(\.name)) ?? [] }.value
            interfaces = names
        }
    }
    func stop() {
        processDetails.stop()
        task?.cancel(); generation += 1
        notifications.synchronize(active: activeAlerts, sound: settings.alerts.sound, eligible: [])
    }
}
