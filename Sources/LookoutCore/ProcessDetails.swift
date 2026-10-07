import Darwin
import Foundation

public struct ProcessUsage: Identifiable, Sendable {
    public let id: EnergyProcessID
    public let name: String
    public let primary: Double
    public let secondary: Double?
    public init(id: EnergyProcessID, name: String, primary: Double, secondary: Double? = nil) {
        self.id = id; self.name = name; self.primary = primary; self.secondary = secondary
    }
    var total: Double { primary + (secondary ?? 0) }
}

public struct ProcessListReading: Sendable {
    public let processes: [ProcessUsage]
    public let message: String?
    public init(processes: [ProcessUsage] = [], message: String? = nil) {
        self.processes = Array(processes.filter { $0.primary.isFinite && $0.primary >= 0 &&
            ($0.secondary == nil || ($0.secondary!.isFinite && $0.secondary! >= 0)) && $0.total > 0 }
            .sorted { $0.total == $1.total ? $0.id.pid < $1.id.pid : $0.total > $1.total }.prefix(5))
        self.message = message
    }
}

struct ProcessResourceCounter: Sendable {
    let id: EnergyProcessID
    let name: String
    let userTime: UInt64
    let systemTime: UInt64
    let memory: UInt64
    let read: UInt64
    let write: UInt64
    let uptime: Double
}

struct ProcessResourceState {
    private var previous: [EnergyProcessID: ProcessResourceCounter] = [:]
    private let nanosecondsPerTick: Double
    init(nanosecondsPerTick: Double) { self.nanosecondsPerTick = nanosecondsPerTick }
    mutating func reset() { previous.removeAll() }
    mutating func sample(_ counters: [ProcessResourceCounter], metrics: Set<Metric>) -> [Metric: ProcessListReading] {
        let current = Dictionary(counters.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        defer { previous = current }
        var result: [Metric: ProcessListReading] = [:]
        for metric in metrics.intersection([.cpu, .memory, .disk]) {
            let rows = current.values.compactMap { counter -> ProcessUsage? in
                if metric == .memory {
                    return ProcessUsage(id: counter.id, name: counter.name, primary: Double(counter.memory))
                }
                guard let old = previous[counter.id] else { return nil }
                let elapsed = counter.uptime - old.uptime
                guard elapsed.isFinite, elapsed > 0 else { return nil }
                if metric == .cpu {
                    guard counter.userTime >= old.userTime, counter.systemTime >= old.systemTime else { return nil }
                    let nanoseconds = (Double(counter.userTime - old.userTime) + Double(counter.systemTime - old.systemTime)) * nanosecondsPerTick
                    // libproc rusage CPU times use Mach ticks; convert with this machine's timebase.
                    return ProcessUsage(id: counter.id, name: counter.name, primary: nanoseconds / 1e9 / elapsed * 100)
                }
                guard counter.read >= old.read, counter.write >= old.write else { return nil }
                return ProcessUsage(id: counter.id, name: counter.name, primary: Double(counter.read - old.read) / elapsed,
                                    secondary: Double(counter.write - old.write) / elapsed)
            }
            result[metric] = ProcessListReading(processes: rows, message: counters.isEmpty ? L10n.text("접근 가능한 프로세스가 없습니다.") :
                rows.isEmpty && metric != .memory ? L10n.text("다음 프로세스 측정을 기다리는 중") : nil)
        }
        return result
    }
}

struct ProcessResourceCollector {
    private var names: [EnergyProcessID: String] = [:]
    mutating func reset() { names.removeAll() }
    mutating func collect() throws -> [ProcessResourceCounter] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw CollectionError.system(L10n.text("프로세스 목록을 읽을 수 없습니다.")) }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0, actual <= pids.count else { throw CollectionError.system(L10n.text("프로세스 목록을 읽을 수 없습니다.")) }
        var counters: [ProcessResourceCounter] = []
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            let id = EnergyProcessID(pid: pid, started: info.ri_proc_start_abstime)
            if names[id] == nil { names[id] = EnergyCollector.processName(pid) }
            counters.append(ProcessResourceCounter(id: id, name: names[id]!, userTime: info.ri_user_time,
                systemTime: info.ri_system_time, memory: info.ri_phys_footprint, read: info.ri_diskio_bytesread,
                write: info.ri_diskio_byteswritten, uptime: ProcessInfo.processInfo.systemUptime))
        }
        let ids = Set(counters.map(\.id)); names = names.filter { ids.contains($0.key) }
        return counters
    }
}

/// One resource scan for all expanded detail sections. Independent of menu-bar sampling.
public actor ProcessDetailSampler {
    private var resources = ProcessResourceCollector()
    private var state: ProcessResourceState
    private var gpu = GPUProcessCollector()
    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        state = ProcessResourceState(nanosecondsPerTick: Double(timebase.numer) / Double(max(1, timebase.denom)))
    }
    public func reset() { resources.reset(); state.reset(); gpu.reset() }
    public func collect(_ metrics: Set<Metric>) async -> [Metric: ProcessListReading] {
        guard !metrics.isEmpty else { reset(); return [:] }
        var result: [Metric: ProcessListReading] = [:]
        if !metrics.intersection([.cpu, .memory, .disk, .gpu]).isEmpty {
            do {
                let counters = try resources.collect()
                result = state.sample(counters, metrics: metrics)
                if metrics.contains(.gpu) {
                    do { result[.gpu] = try gpu.collect(processes: counters) }
                    catch { gpu.reset(); result[.gpu] = ProcessListReading(message: error.localizedDescription) }
                } else { gpu.reset() }
            } catch {
                state.reset(); gpu.reset()
                for metric in metrics.intersection([.cpu, .memory, .disk, .gpu]) {
                    result[metric] = ProcessListReading(message: error.localizedDescription)
                }
            }
        } else { resources.reset(); state.reset(); gpu.reset() }
        if metrics.contains(.network) { result[.network] = await NetworkProcessCollector.collect() }
        return result
    }
}
