import Darwin
import Foundation
import IOKit.pwr_mgt

public struct EnergyProcessID: Hashable, Sendable {
    public let pid: Int32
    public let started: UInt64
    public init(pid: Int32, started: UInt64) { self.pid = pid; self.started = started }
}
public struct EnergyProcessCounter: Sendable {
    public let id: EnergyProcessID
    public let name: String
    public let nanojoules: UInt64
    public let uptime: Double
    public init(id: EnergyProcessID, name: String, nanojoules: UInt64, uptime: Double) {
        self.id = id; self.name = name; self.nanojoules = nanojoules; self.uptime = uptime
    }
    public func watts(since previous: EnergyProcessCounter) -> Double? {
        let elapsed = uptime - previous.uptime
        guard id == previous.id, elapsed.isFinite, elapsed > 0, nanojoules >= previous.nanojoules else { return nil }
        return Double(nanojoules - previous.nanojoules) / 1e9 / elapsed
    }
}
public struct EnergyProcessReading: Identifiable, Sendable {
    public let id: EnergyProcessID
    public let name: String
    public let watts: Double
    public init(id: EnergyProcessID, name: String, watts: Double) { self.id = id; self.name = name; self.watts = watts }
}
public struct SleepPreventer: Identifiable, Sendable {
    public let pid: Int32
    public let name: String
    public var id: Int32 { pid }
    public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
}
public struct PowerReading: Sendable {
    public let watts: Double?
    public let processes: [EnergyProcessReading]
    public let measuredCount: Int
    public let readableCount: Int
    public let totalCount: Int
    /// nil means the assertions API failed; an empty list means no matching active assertion.
    public let sleepPreventers: [SleepPreventer]?
    public let message: String?
    public init(watts: Double?, processes: [EnergyProcessReading] = [], measuredCount: Int = 0,
                readableCount: Int = 0, totalCount: Int = 0, sleepPreventers: [SleepPreventer]? = nil,
                message: String? = nil) {
        self.watts = watts; self.processes = processes; self.measuredCount = measuredCount
        self.readableCount = readableCount; self.totalCount = totalCount
        self.sleepPreventers = sleepPreventers; self.message = message
    }
}

public struct EnergySamplingState: Sendable {
    private var previous: [EnergyProcessID: EnergyProcessCounter] = [:]
    public init() {}
    public mutating func reset() { previous.removeAll() }
    public mutating func sample(counters: [EnergyProcessCounter], totalCount: Int,
                                sleepPreventers: [SleepPreventer]?, supported: Bool = true) -> PowerReading {
        let unique = Dictionary(counters.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let rates = supported ? unique.values.compactMap { counter -> EnergyProcessReading? in
            guard let prior = previous[counter.id], let watts = counter.watts(since: prior) else { return nil }
            return EnergyProcessReading(id: counter.id, name: counter.name, watts: watts)
        } : []
        previous = supported ? unique : [:]
        let sorted = rates.sorted { $0.watts == $1.watts ? $0.id.pid < $1.id.pid : $0.watts > $1.watts }
        return PowerReading(watts: rates.isEmpty ? nil : rates.reduce(0) { $0 + $1.watts },
                            processes: Array(sorted.filter { $0.watts > 0 }.prefix(5)), measuredCount: rates.count,
                            readableCount: unique.count, totalCount: totalCount, sleepPreventers: sleepPreventers,
                            message: !supported ? "이 Mac에서 프로세스 에너지 통계를 제공하지 않습니다." :
                                rates.isEmpty ? "다음 에너지 측정을 기다리는 중" : nil)
    }
}

/// Public libproc counters, limited to processes this app is permitted to inspect.
/// This is not Activity Monitor's relative Energy Impact score or whole-device wall power.
struct EnergyCollector {
    private var names: [EnergyProcessID: String] = [:]
    private var state = EnergySamplingState()
    mutating func reset() { names.removeAll(); state.reset() }
    mutating func collect() throws -> PowerReading {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { state.reset(); throw CollectionError.system("프로세스 목록을 읽을 수 없습니다.") }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0, actual <= pids.count else { state.reset(); throw CollectionError.system("프로세스 목록을 읽을 수 없습니다.") }
        var counters: [EnergyProcessCounter] = []
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var info = rusage_info_v6()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                // libproc's historical rusage_info_t typedef imports as a pointer-to-pointer;
                // the C function actually writes the rusage struct into this buffer.
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard result == 0 else { continue }
            let id = EnergyProcessID(pid: pid, started: info.ri_proc_start_abstime)
            if names[id] == nil { names[id] = Self.processName(pid) }
            counters.append(EnergyProcessCounter(id: id, name: names[id]!, nanojoules: info.ri_energy_nj,
                                                  uptime: ProcessInfo.processInfo.systemUptime))
        }
        let ids = Set(counters.map(\.id)); names = names.filter { ids.contains($0.key) }
        // Intel/unsupported counters can return zero-filled fields. Do not present them as measured zero W.
        #if arch(arm64)
        let supported = counters.contains { $0.nanojoules > 0 }
        #else
        let supported = false
        #endif
        return state.sample(counters: counters, totalCount: pids.prefix(Int(actual)).filter { $0 > 0 }.count,
                            sleepPreventers: Self.sleepPreventers(), supported: supported)
    }
    static func processName(_ pid: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        if count > 0 { return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        // proc_name may deny another user's process; public sysctl still exposes its short name.
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size {
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if !name.isEmpty { return name }
        }
        return "PID \(pid)"
    }
    static func isSleepPreventingAssertion(type: String?, level: Int?) -> Bool {
        guard level == Int(kIOPMAssertionLevelOn), let type else { return false }
        return [kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                kIOPMAssertionTypePreventSystemSleep as String, "NoIdleSleepAssertion"].contains(type)
    }
    private static func sleepPreventers() -> [SleepPreventer]? {
        var values: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&values) == kIOReturnSuccess,
              let assertions = values?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        return assertions.compactMap { pid, entries in
            guard entries.contains(where: { isSleepPreventingAssertion(type: $0[kIOPMAssertionTypeKey] as? String,
                level: ($0[kIOPMAssertionLevelKey] as? NSNumber)?.intValue) }) else { return nil }
            return SleepPreventer(pid: pid.int32Value, name: processName(pid.int32Value))
        }.sorted { $0.pid < $1.pid }
    }
}
