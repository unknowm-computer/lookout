import Foundation
import IOKit

extension SystemMetrics {
    /// APFS's writable Data volume shares the startup container's free space.
    public static func disk() throws -> DiskReading {
        let path = startupDataPath
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ])
        guard let total = values.volumeTotalCapacity, total > 0 else {
            throw CollectionError.system("시작 디스크 용량을 읽을 수 없습니다.")
        }
        // Query separately so an unsupported reclaimable-capacity API does not lose basic capacity.
        let reclaimableValues = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = try availableStorageCapacity(total: total, free: values.volumeAvailableCapacity,
            important: reclaimableValues?.volumeAvailableCapacityForImportantUsage)
        return DiskReading(name: values.volumeName ?? "시작 디스크", total: Double(total), available: available)
    }

    /// Include macOS-reclaimable storage, as Storage settings does, without estimating caches ourselves.
    static func availableStorageCapacity(total: Int, free: Int?, important: Int64?) throws -> Double {
        guard total > 0 else { throw CollectionError.system("시작 디스크 용량을 읽을 수 없습니다.") }
        let validFree = free.flatMap { (0...total).contains($0) ? $0 : nil }
        if let important, important >= Int64(validFree ?? 0), important <= Int64(total) {
            return Double(important)
        }
        guard let validFree else { throw CollectionError.system("시작 디스크 여유 공간을 읽을 수 없습니다.") }
        return Double(validFree)
    }

    /// Driver-provided statistics are optional and do not have a stable public schema.
    /// Select one device consistently by registry ID rather than summing multiple GPUs.
    public static func gpu() throws -> GPUReading {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            throw CollectionError.system("GPU 통계를 읽을 수 없습니다.")
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [(UInt64, GPUReading)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, nil, 0)?.takeRetainedValue()
            let name: String
            if let text = model as? String { name = text }
            else if let data = model as? Data { name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self) }
            else { name = "GPU" }
            if let reading = GPUReading.from(statistics: stats, name: name) {
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
                candidates.append((id, reading))
            }
        }
        guard let reading = candidates.min(by: { $0.0 < $1.0 })?.1 else {
            throw CollectionError.system("이 Mac 또는 macOS에서 GPU 사용률 통계를 제공하지 않습니다.")
        }
        return reading
    }
}

extension GPUReading {
    public static func from(statistics: [String: Any], name: String) -> GPUReading? {
        func percentage(_ key: String) -> Double? {
            guard let value = (statistics[key] as? NSNumber)?.doubleValue,
                  value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        guard let usage = percentage("Device Utilization %") else { return nil }
        let memory = (statistics["In use system memory"] as? NSNumber)?.doubleValue
        return GPUReading(name: name, utilization: usage, renderer: percentage("Renderer Utilization %"),
                          tiler: percentage("Tiler Utilization %"),
                          sharedMemory: memory.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
}
