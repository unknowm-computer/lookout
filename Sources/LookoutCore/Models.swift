import Foundation

public enum Metric: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, memory, network, disk, power, gpu
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: "CPU"; case .memory: "메모리"; case .network: "네트워크"
        case .disk: "디스크"; case .power: "에너지"; case .gpu: "GPU"
        }
    }
    public var symbol: String {
        switch self {
        case .cpu: "cpu"; case .memory: "memorychip"; case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"; case .power: "bolt.fill"; case .gpu: "square.3.layers.3d"
        }
    }
    public var menuTitle: String {
        switch self {
        case .cpu: "CPU"; case .memory: "MEM"; case .network: "NET"
        case .disk: "SSD"; case .power: "ENG"; case .gpu: "GPU"
        }
    }
}

public struct MonitorConfiguration: Equatable, Sendable {
    public var enabled: Set<Metric>
    public var order: [Metric]
    public var interval: Int
    public var interface: String?
    public init(enabled: Set<Metric> = Set(Metric.allCases), order: [Metric] = Metric.allCases,
                interval: Int = 2, interface: String? = nil) {
        self.enabled = enabled
        var seen: Set<Metric> = []
        self.order = (order + Metric.allCases).filter { seen.insert($0).inserted }
        self.interval = [1, 2, 5].contains(interval) ? interval : 2
        self.interface = interface
    }
    public var visible: [Metric] { order.filter { enabled.contains($0) } }
}

/// Raw identifiers allow older builds to ignore settings for unknown future metrics.
public struct SettingsRecord: Codable, Sendable {
    public var version: Int = 1
    public var enabled: [String]?
    public var order: [String]?
    public var interval: Int?
    public var interface: String?
    public init(configuration: MonitorConfiguration) {
        enabled = configuration.enabled.map(\.rawValue).sorted()
        order = configuration.order.map(\.rawValue)
        interval = configuration.interval
        interface = configuration.interface
    }
    public var configuration: MonitorConfiguration {
        MonitorConfiguration(
            enabled: enabled.map { Set($0.compactMap(Metric.init(rawValue:))) } ?? Set(Metric.allCases),
            order: order?.compactMap(Metric.init(rawValue:)) ?? Metric.allCases,
            interval: interval ?? 2, interface: interface
        )
    }
}

public struct MemoryReading: Sendable {
    public let total: Double
    public let app: Double
    public let wired: Double
    public let compressed: Double
    public let swap: Double?
    public var used: Double { app + wired + compressed }
    public var percent: Double { min(100, max(0, used / total * 100)) }
    public init(total: Double, app: Double, wired: Double, compressed: Double, swap: Double?) {
        self.total = total; self.app = app; self.wired = wired
        self.compressed = compressed; self.swap = swap
    }
}

public struct NetworkReading: Sendable {
    public let interface: String
    public let download: Double
    public let upload: Double
    public init(interface: String, download: Double, upload: Double) {
        self.interface = interface; self.download = download; self.upload = upload
    }
}

public struct DiskCapacityReading: Sendable {
    public let name: String
    public let total: Double
    public let available: Double
    public let sampledAt: Date?
    public let uptime: Double?
    public var used: Double { max(0, total - available) }
    public var percent: Double { total > 0 ? min(100, max(0, used / total * 100)) : 0 }
    public init(name: String, total: Double, available: Double, sampledAt: Date? = nil, uptime: Double? = nil) {
        self.name = name; self.total = total; self.available = min(total, max(0, available))
        self.sampledAt = sampledAt; self.uptime = uptime
    }
}

public struct DiskActivityReading: Sendable {
    public let read: Double
    public let write: Double
    public init(read: Double, write: Double) { self.read = read; self.write = write }
}

public struct DiskReading: Sendable {
    public let capacity: DiskCapacityReading?
    public let activity: DiskActivityReading?
    public let activityMessage: String?
    public let capacityMessage: String?
    public var name: String { capacity?.name ?? "시작 디스크" }
    public var total: Double { capacity?.total ?? 0 }
    public var available: Double { capacity?.available ?? 0 }
    public var used: Double { capacity?.used ?? 0 }
    public var percent: Double { capacity?.percent ?? 0 }
    public init(name: String, total: Double, available: Double) {
        self.init(capacity: DiskCapacityReading(name: name, total: total, available: available))
    }
    public init(capacity: DiskCapacityReading?, activity: DiskActivityReading? = nil,
                activityMessage: String? = nil, capacityMessage: String? = nil) {
        self.capacity = capacity; self.activity = activity
        self.activityMessage = activityMessage; self.capacityMessage = capacityMessage
    }
}

public struct GPUReading: Sendable {
    public let name: String
    public let utilization: Double
    public let renderer: Double?
    public let tiler: Double?
    public let sharedMemory: Double?
    public init(name: String, utilization: Double, renderer: Double?, tiler: Double?, sharedMemory: Double?) {
        self.name = name; self.utilization = utilization; self.renderer = renderer
        self.tiler = tiler; self.sharedMemory = sharedMemory
    }
}

public enum ReadingValue: Sendable {
    case cpu(Double)
    case memory(MemoryReading)
    case network(NetworkReading)
    case disk(DiskReading)
    case power(PowerReading)
    case gpu(GPUReading)
    public var primary: Double? {
        switch self {
        case .cpu(let value): value; case .memory(let value): value.percent; case .network(let value): value.download
        case .disk(let value): value.activity?.read; case .power(let value): value.watts; case .gpu(let value): value.utilization
        }
    }
    public var secondary: Double? {
        if case .network(let value) = self { return value.upload }
        if case .disk(let value) = self { return value.activity?.write }
        return nil
    }
}

public struct MetricReading: Sendable {
    public let metric: Metric
    public let date: Date
    public let value: ReadingValue?
    public let message: String?
    public init(metric: Metric, date: Date, value: ReadingValue?, message: String? = nil) {
        self.metric = metric; self.date = date; self.value = value; self.message = message
    }
}

public struct HistoryPoint: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let primary: Double?
    public let secondary: Double?
    public let segment: Int
}

public struct HistoryBuffer: Sendable {
    public private(set) var points: [HistoryPoint] = []
    private var segment: Int = 0
    private var previousDate: Date?
    public init() {}
    public mutating func append(_ reading: MetricReading, interval: Int) {
        if reading.value?.primary == nil || previousDate.map({ reading.date.timeIntervalSince($0) > Double(interval) * 2.5 }) == true {
            segment += 1
        }
        points.append(HistoryPoint(id: UUID(), date: reading.date, primary: reading.value?.primary,
                                   secondary: reading.value?.secondary, segment: segment))
        previousDate = reading.date
        prune(at: reading.date)
    }
    public mutating func breakContinuity() { segment += 1; previousDate = nil }
    public mutating func prune(at date: Date) {
        points.removeAll { $0.date < date.addingTimeInterval(-300) }
        if points.count > 301 { points.removeFirst(points.count - 301) }
    }
}

public enum ValueFormat {
    public static func watts(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1 W" }
        return String(format: "%.1f W", value)
    }
    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    public static func memory(_ bytes: Double) -> String {
        let divisor = bytes >= 1_073_741_824 ? 1_073_741_824.0 : 1_048_576.0
        return String(format: "%.1f %@", bytes / divisor, divisor > 1_048_576 ? "GiB" : "MiB")
    }
    public static func storage(_ bytes: Double) -> String {
        String(format: "%.1f %@", bytes / (bytes >= 1e12 ? 1e12 : 1e9), bytes >= 1e12 ? "TB" : "GB")
    }
    public static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
    public static func rate(_ bytes: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytes), index = 0
        while value >= 1000 && index < 3 { value /= 1000; index += 1 }
        return String(format: index == 0 || value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
