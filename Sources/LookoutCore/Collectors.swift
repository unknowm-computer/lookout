import Darwin
import Foundation
import SystemConfiguration

public struct CPUTicks: Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 = 0) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    public func usage(since old: CPUTicks) -> Double? {
        let current = [user, system, idle, nice], previous = [old.user, old.system, old.idle, old.nice]
        guard zip(current, previous).allSatisfy({ $0 >= $1 }) else { return nil }
        let delta = zip(current, previous).map { $0 - $1 }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - delta[2]) / Double(total) * 100
    }
}

public struct NetworkCounter: Sendable {
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public let uptime: Double
    public init(name: String, received: UInt64, sent: UInt64, uptime: Double) {
        self.name = name; self.received = received; self.sent = sent; self.uptime = uptime
    }
    public func rate(since old: NetworkCounter) -> NetworkReading? {
        let duration = uptime - old.uptime
        guard name == old.name, duration > 0, received >= old.received, sent >= old.sent else { return nil }
        return NetworkReading(interface: name, download: Double(received - old.received) / duration,
                              upload: Double(sent - old.sent) / duration)
    }
}

public enum CollectionError: Error, LocalizedError {
    case system(String)
    public var errorDescription: String? { if case .system(let message) = self { return message }; return nil }
}

public enum SystemMetrics {
    public static func cpu() throws -> CPUTicks {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: capacity) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw CollectionError.system(L10n.text("CPU 통계를 읽을 수 없습니다 (\(result)).")) }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    public static func memory() throws -> MemoryReading {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { throw CollectionError.system(L10n.text("메모리 페이지 크기를 읽을 수 없습니다.")) }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: capacity) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw CollectionError.system(L10n.text("메모리 통계를 읽을 수 없습니다 (\(result)).")) }
        let page = Double(pageSize)
        // Anonymous resident pages exclude compressed storage. Reclaimable purgeable pages are not app memory.
        let app = max(0, Double(info.internal_page_count) - Double(info.purgeable_count)) * page
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var pressure: UInt32 = 0
        var pressureSize = MemoryLayout<UInt32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        return MemoryReading(total: Double(ProcessInfo.processInfo.physicalMemory), app: app,
                             wired: Double(info.wire_count) * page,
                             compressed: Double(info.compressor_page_count) * page,
                             swap: swapResult == 0 ? Double(swap.xsu_used) : nil,
                             swapTotal: swapResult == 0 ? Double(swap.xsu_total) : nil,
                             pressure: pressureResult == 0 ? MemoryPressure(rawValue: pressure) : nil)
    }

    public static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Lookout" as CFString, nil, nil) else { return nil }
        for family in ["IPv4", "IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    /// NET_RT_IFLIST2 exposes 64-bit byte counters; getifaddrs' if_data counters can wrap at 4 GiB.
    public static func interfaces() throws -> [NetworkCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { throw CollectionError.system(L10n.text("네트워크 통계를 읽을 수 없습니다.")) }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { throw CollectionError.system(L10n.text("네트워크 통계를 읽을 수 없습니다.")) }
        let uptime = ProcessInfo.processInfo.systemUptime
        return data.withUnsafeBytes { buffer in
            var result: [NetworkCounter] = [], offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let pointer = buffer.baseAddress!.advanced(by: offset)
                let header = pointer.loadUnaligned(as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let info = pointer.loadUnaligned(as: if_msghdr2.self)
                    if info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_LOOPBACK == 0 {
                        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                        if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                            let interfaceName = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                            result.append(NetworkCounter(name: interfaceName, received: info.ifm_data.ifi_ibytes,
                                                         sent: info.ifm_data.ifi_obytes, uptime: uptime))
                        }
                    }
                }
                offset += length
            }
            return result.sorted { $0.name < $1.name }
        }
    }
}

public actor MetricSampler {
    private var energyCollector = EnergyCollector()
    private var diskState = DiskSamplingState()
    private var previousCPU: CPUTicks?
    private var previousNetwork: NetworkCounter?
    private var configuration = MonitorConfiguration(enabled: [])
    private var counts: [Metric: Int] = [:]
    private let capabilities: MonitoringCapabilities
    public init(capabilities: MonitoringCapabilities = .current) { self.capabilities = capabilities }
    public func reset() { previousCPU = nil; previousNetwork = nil; diskState.reset(); energyCollector.reset() }
    public func invocationCounts() -> [Metric: Int] { counts }
    public func collect(_ config: MonitorConfiguration, date: Date = Date()) -> [MetricReading] {
        let config = capabilities.applying(to: config)
        if !config.enabled.contains(.cpu) { previousCPU = nil }
        if !config.enabled.contains(.network) || config.interface != configuration.interface { previousNetwork = nil }
        if !config.needsStorageCapacity && !config.enabled.contains(.disk) { diskState.reset() }
        if !config.enabled.contains(.power) { energyCollector.reset() }
        configuration = config
        // SSD capacity and disk I/O have independent demand and polling intervals.
        let disk = !config.needsStorageCapacity && !config.enabled.contains(.disk) ? nil :
            diskState.sample(uptime: ProcessInfo.processInfo.systemUptime, date: date,
                             readCapacity: { try SystemMetrics.disk() }, readCounters: { try SystemMetrics.diskCounters() },
                             collectActivity: config.enabled.contains(.disk), collectCapacity: config.needsStorageCapacity,
                             capacityInterval: config.storageInterval)
        return config.visible.map { metric in
            counts[metric, default: 0] += 1
            do {
                switch metric {
                case .cpu:
                    let current = try SystemMetrics.cpu()
                    let value = previousCPU.flatMap { current.usage(since: $0) }
                    previousCPU = current
                    return MetricReading(metric: metric, date: date, value: value.map(ReadingValue.cpu),
                                         message: value == nil ? L10n.text("다음 측정을 기다리는 중") : nil)
                case .memory:
                    return MetricReading(metric: metric, date: date, value: .memory(try SystemMetrics.memory()))
                case .ssd:
                    return MetricReading(metric: metric, date: date, value: disk?.capacity.map(ReadingValue.storage),
                                         message: disk?.capacityMessage)
                case .disk:
                    return MetricReading(metric: metric, date: date, value: disk.map(ReadingValue.disk))
                case .power:
                    return MetricReading(metric: metric, date: date, value: .power(try energyCollector.collect()))
                case .gpu:
                    return MetricReading(metric: metric, date: date, value: .gpu(try SystemMetrics.gpu()))
                case .network:
                    let interfaces = try SystemMetrics.interfaces()
                    let name = config.interface ?? SystemMetrics.primaryInterface()
                    guard let counter = interfaces.first(where: { $0.name == name }) else {
                        previousNetwork = nil
                        return MetricReading(metric: metric, date: date, value: nil,
                                             message: config.interface == nil ? L10n.text("네트워크 연결 없음") : L10n.text("선택한 인터페이스를 사용할 수 없습니다"))
                    }
                    let value = previousNetwork.flatMap { counter.rate(since: $0) }
                    previousNetwork = counter
                    return MetricReading(metric: metric, date: date, value: value.map(ReadingValue.network),
                                         message: value == nil ? L10n.text("\(counter.name) · 다음 측정을 기다리는 중") : nil)
                }
            } catch {
                if metric == .cpu { previousCPU = nil }
                if metric == .network { previousNetwork = nil }
                return MetricReading(metric: metric, date: date, value: nil, message: error.localizedDescription)
            }
        }
    }
}
