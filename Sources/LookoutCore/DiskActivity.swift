import Darwin
import Foundation
import IOKit

public struct DiskDeviceCounter: Sendable {
    public let id: UInt64
    public let read: UInt64
    public let write: UInt64
    public init(id: UInt64, read: UInt64, write: UInt64) { self.id = id; self.read = read; self.write = write }
}

public struct DiskCounter: Sendable {
    public let devices: [DiskDeviceCounter]
    public let uptime: Double
    public init(devices: [DiskDeviceCounter], uptime: Double) { self.devices = devices; self.uptime = uptime }
    public func rate(since old: DiskCounter) -> DiskActivityReading? {
        let elapsed = uptime - old.uptime
        let current = devices.sorted { $0.id < $1.id }, previous = old.devices.sorted { $0.id < $1.id }
        guard elapsed.isFinite, elapsed > 0, !current.isEmpty,
              Set(current.map(\.id)).count == current.count,
              current.map(\.id) == previous.map(\.id) else { return nil }
        var read = 0.0, write = 0.0
        for (now, prior) in zip(current, previous) {
            guard now.read >= prior.read, now.write >= prior.write else { return nil }
            read += Double(now.read - prior.read); write += Double(now.write - prior.write)
        }
        return DiskActivityReading(read: read / elapsed, write: write / elapsed)
    }
}

/// Capacity and activity can fail independently. No extra timer; disabled/sleeping sampling resets this state.
public struct DiskSamplingState: Sendable {
    private var previous: DiskCounter?
    private var capacity: DiskCapacityReading?
    private var capacityAttempt: Double?
    private var capacityMessage: String?
    public init() {}
    public mutating func reset() { self = DiskSamplingState() }
    public mutating func sample(uptime: Double, date: Date,
                                readCapacity: () throws -> DiskReading,
                                readCounters: () throws -> DiskCounter) -> DiskReading {
        if capacityAttempt.map({ uptime < $0 || uptime - $0 >= 30 }) ?? true {
            capacityAttempt = uptime
            do {
                let value = try readCapacity()
                guard value.total > 0, value.total.isFinite, value.available.isFinite else {
                    throw CollectionError.system("저장공간 정보를 읽을 수 없습니다.")
                }
                capacity = DiskCapacityReading(name: value.name, total: value.total, available: value.available,
                                               sampledAt: date, uptime: uptime)
                capacityMessage = nil
            } catch {
                capacity = nil; capacityMessage = error.localizedDescription
            }
        }
        var activity: DiskActivityReading?, message: String?
        do {
            let counter = try readCounters()
            activity = previous.flatMap { counter.rate(since: $0) }
            previous = counter
            if activity == nil { message = "다음 디스크 측정을 기다리는 중" }
        } catch {
            previous = nil; message = error.localizedDescription
        }
        return DiskReading(capacity: capacity, activity: activity,
                           activityMessage: message, capacityMessage: capacityMessage)
    }
}

extension SystemMetrics {
    static var startupDataPath: String {
        FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
    }
    /// Walk the mounted Data volume's service ancestors. Count each backing driver once;
    /// do not sum APFS volumes, unrelated external devices, or mounted disk images.
    public static func diskCounters() throws -> DiskCounter {
        var fs = statfs()
        guard statfs(startupDataPath, &fs) == 0 else { throw CollectionError.system("시작 디스크 장치를 찾을 수 없습니다.") }
        let device = withUnsafePointer(to: &fs.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { throw CollectionError.system("시작 디스크 I/O를 지원하지 않습니다.") }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, String(device.dropFirst(5))))
        guard service != 0 else { throw CollectionError.system("시작 디스크 I/O 장치를 찾을 수 없습니다.") }
        defer { IOObjectRelease(service) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents), &iterator) == KERN_SUCCESS else {
            throw CollectionError.system("시작 디스크 I/O 통계를 읽을 수 없습니다.")
        }
        defer { IOObjectRelease(iterator) }
        var counters: [UInt64: DiskDeviceCounter] = [:]
        while case let parent = IOIteratorNext(iterator), parent != 0 {
            defer { IOObjectRelease(parent) }
            guard IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS,
                  let stats = IORegistryEntryCreateCFProperty(parent, "Statistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber, let write = stats["Bytes (Write)"] as? NSNumber,
                  read.doubleValue >= 0, write.doubleValue >= 0 else {
                throw CollectionError.system("시작 디스크 I/O 통계가 제공되지 않습니다.")
            }
            counters[id] = DiskDeviceCounter(id: id, read: read.uint64Value, write: write.uint64Value)
        }
        guard IOIteratorIsValid(iterator) != 0, !counters.isEmpty else { throw CollectionError.system("이 Mac에서 시작 디스크 I/O 통계를 제공하지 않습니다.") }
        return DiskCounter(devices: counters.values.sorted { $0.id < $1.id }, uptime: ProcessInfo.processInfo.systemUptime)
    }
}
