import Foundation

public enum Metric: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, memory, ssd, network, disk, power, gpu
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: "CPU"; case .memory: L10n.text("메모리"); case .network: L10n.text("네트워크")
        case .disk: L10n.text("디스크"); case .ssd: "SSD"; case .power: L10n.text("에너지"); case .gpu: "GPU"
        }
    }
    public var symbol: String {
        switch self {
        case .cpu: "cpu"; case .memory: "memorychip"; case .network: "arrow.up.arrow.down"
        case .disk, .ssd: "internaldrive"; case .power: "bolt.fill"; case .gpu: "square.3.layers.3d"
        }
    }
    public var menuTitle: String {
        switch self {
        case .cpu: "CPU"; case .memory: "MEM"; case .network: "NET"
        case .disk: "DISK"; case .ssd: "SSD"; case .power: "ENG"; case .gpu: "GPU"
        }
    }
}

public struct MonitorConfiguration: Equatable, Sendable {
    public static let defaultInterval = 3
    public var enabled: Set<Metric>
    public var order: [Metric]
    public var interval: Int
    public var interface: String?
    public var storageInterval: Int
    public var menuBarGrouping: MenuBarGrouping
    public var networkRateBasis: ActivityRateBasis
    public var diskRateBasis: ActivityRateBasis
    public init(enabled: Set<Metric> = Set(Metric.allCases), order: [Metric] = Metric.allCases,
                interval: Int = MonitorConfiguration.defaultInterval, interface: String? = nil, storageInterval: Int = 30,
                menuBarGrouping: MenuBarGrouping = MenuBarGrouping(),
                networkRateBasis: ActivityRateBasis = .data, diskRateBasis: ActivityRateBasis = .data) {
        self.enabled = enabled
        var seen: Set<Metric> = []
        self.order = (order + Metric.allCases).filter { seen.insert($0).inserted }
        self.interval = [1, 2, 3, 5].contains(interval) ? interval : Self.defaultInterval
        self.interface = interface
        self.storageInterval = StoragePollingInterval(rawValue: storageInterval)?.rawValue ?? 30
        self.menuBarGrouping = menuBarGrouping
        self.networkRateBasis = networkRateBasis; self.diskRateBasis = diskRateBasis
    }
    public var visible: [Metric] { order.filter { enabled.contains($0) } }
    /// Detail panels follow group placement and show the upper member before its partner.
    public var detailMetrics: [Metric] { menuBarGrouping.units(metrics: visible).flatMap(\.metrics) }
    public var needsStorageCapacity: Bool {
        enabled.contains(.ssd)
    }
}

/// Raw identifiers allow older builds to ignore settings for unknown future metrics.
public struct SettingsRecord: Codable, Sendable {
    public var version: Int = 2
    public var enabled: [String]?
    public var order: [String]?
    public var interval: Int?
    public var interface: String?
    public var showsMemoryStorage: Bool?
    public var storageInterval: Int?
    public var menuBarGrouping: MenuBarGrouping?
    public var networkRateBasis: String?
    public var diskRateBasis: String?
    public init(configuration: MonitorConfiguration) {
        enabled = configuration.enabled.map(\.rawValue).sorted()
        order = configuration.order.map(\.rawValue)
        interval = configuration.interval
        interface = configuration.interface
        storageInterval = configuration.storageInterval
        menuBarGrouping = configuration.menuBarGrouping
        networkRateBasis = configuration.networkRateBasis.rawValue
        diskRateBasis = configuration.diskRateBasis.rawValue
    }
    public var configuration: MonitorConfiguration {
        var selected = enabled.map { Set($0.compactMap(Metric.init(rawValue:))) } ?? Set(Metric.allCases)
        var placement = order?.compactMap(Metric.init(rawValue:)) ?? Metric.allCases
        if version < 2, !selected.contains(.ssd) {
            if selected.contains(.memory), showsMemoryStorage ?? true { selected.insert(.ssd) }
        }
        if !placement.contains(.ssd), let index = placement.firstIndex(of: .memory) {
            placement.insert(.ssd, at: index + 1)
        }
        return MonitorConfiguration(
            enabled: selected, order: placement,
            interval: interval ?? MonitorConfiguration.defaultInterval, interface: interface, storageInterval: storageInterval ?? 30,
            menuBarGrouping: menuBarGrouping ?? MenuBarGrouping(),
            networkRateBasis: networkRateBasis.flatMap(ActivityRateBasis.init(rawValue:)) ?? .data,
            diskRateBasis: diskRateBasis.flatMap(ActivityRateBasis.init(rawValue:)) ?? .data
        )
    }
}

public struct MemoryReading: Sendable {
    public let total: Double
    public let app: Double
    public let wired: Double
    public let compressed: Double
    public let swap: Double?
    public let swapTotal: Double?
    public let pressure: MemoryPressure?
    public var used: Double { app + wired + compressed }
    public var available: Double { max(0, total - used) }
    public var percent: Double { min(100, max(0, used / total * 100)) }
    public var swapPercent: Double? {
        guard let swap, let swapTotal, swap.isFinite, swapTotal.isFinite,
              swap >= 0, swapTotal >= 0 else { return nil }
        guard swapTotal > 0 else { return swap == 0 ? 0 : nil }
        return min(100, swap / swapTotal * 100)
    }
    public var swapAvailable: Double? {
        guard swapPercent != nil, let swap, let swapTotal else { return nil }
        return max(0, swapTotal - swap)
    }
    public init(total: Double, app: Double, wired: Double, compressed: Double, swap: Double?,
                swapTotal: Double? = nil, pressure: MemoryPressure? = nil) {
        self.total = total; self.app = app; self.wired = wired
        self.compressed = compressed; self.swap = swap; self.swapTotal = swapTotal; self.pressure = pressure
    }
}

public struct NetworkReading: Sendable {
    public let interface: String
    public let download: Double
    public let upload: Double
    public let basis: ActivityRateBasis
    public init(interface: String, download: Double, upload: Double, basis: ActivityRateBasis = .data) {
        self.interface = interface; self.download = download; self.upload = upload; self.basis = basis
    }
}

public struct DiskCapacityReading: Sendable {
    public let name: String
    public let total: Double
    public let available: Double
    public let sampledAt: Date?
    public let uptime: Double?
    public let pollingInterval: Int
    public var used: Double { max(0, total - available) }
    public var percent: Double { total > 0 ? min(100, max(0, used / total * 100)) : 0 }
    public init(name: String, total: Double, available: Double, sampledAt: Date? = nil, uptime: Double? = nil,
                pollingInterval: Int = 30) {
        self.name = name; self.total = total; self.available = min(total, max(0, available))
        self.sampledAt = sampledAt; self.uptime = uptime
        self.pollingInterval = pollingInterval
    }
}

public struct DiskActivityReading: Sendable {
    public let read: Double
    public let write: Double
    public let basis: ActivityRateBasis
    public init(read: Double, write: Double, basis: ActivityRateBasis = .data) {
        self.read = read; self.write = write; self.basis = basis
    }
}

public struct DiskReading: Sendable {
    public let capacity: DiskCapacityReading?
    public let activity: DiskActivityReading?
    public let activityMessage: String?
    public let capacityMessage: String?
    public var name: String { capacity?.name ?? L10n.text("시작 디스크") }
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
    case storage(DiskCapacityReading)
    case network(NetworkReading)
    case disk(DiskReading)
    case power(PowerReading)
    case gpu(GPUReading)
    public var primary: Double? {
        switch self {
        case .cpu(let value): value; case .memory(let value): value.percent; case .storage(let value): value.percent; case .network(let value): value.download
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
        minutes >= 60 ? L10n.text("\(minutes / 60)시간 \(minutes % 60)분") : L10n.text("\(minutes)분")
    }
    public static func rate(_ bytes: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytes), index = 0
        while value >= 1000 && index < 3 { value /= 1000; index += 1 }
        return String(format: index == 0 || value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
