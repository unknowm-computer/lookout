import Combine
import Foundation
import LookoutCore

@MainActor final class ProcessDetailsStore: ObservableObject {
    @Published private(set) var readings: [Metric: ProcessListReading] = [:]
    private var requests: [UUID: Metric] = [:]
    private var config: MonitorConfiguration
    private var task: Task<Void, Never>?
    private var sleeping = false
    private var generation = 0
    init(configuration: MonitorConfiguration) { config = configuration }
    func setExpanded(_ expanded: Bool, metric: Metric, owner: UUID) {
        let before = requested
        if expanded { requests[owner] = metric } else { requests.removeValue(forKey: owner) }
        if before != requested { restart() }
    }
    func configure(_ configuration: MonitorConfiguration) {
        let changed = config.enabled != configuration.enabled || config.interval != configuration.interval
        config = configuration
        if changed { restart() }
    }
    func suspend() { sleeping = true; restart() }
    func resume() { sleeping = false; restart() }
    func stop() { task?.cancel(); task = nil; generation += 1; readings.removeAll() }
    private var requested: Set<Metric> {
        // Energy already samples processes for its main reading; the view reuses that result.
        Set(requests.values).intersection(config.enabled).subtracting([.power])
    }
    private func restart() {
        stop()
        let metrics = requested, interval = config.interval, token = generation
        guard !sleeping, !metrics.isEmpty else { return }
        let sampler = ProcessDetailSampler()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                let result = await sampler.collect(metrics)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.readings = result
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                do { try await Task.sleep(for: .seconds(max(0.1, Double(interval) - elapsed))) }
                catch { return }
            }
        }
    }
}
