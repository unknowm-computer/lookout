import Foundation
import IOKit

struct GPUClientCounter: Sendable {
    let registryID: UInt64
    let process: EnergyProcessID
    let name: String
    let queueCount: Int
    let nanoseconds: UInt64
    let uptime: Double
}

struct GPUProcessState {
    private var previous: [UInt64: GPUClientCounter] = [:]
    mutating func reset() { previous.removeAll() }
    mutating func sample(_ counters: [GPUClientCounter]) -> ProcessListReading {
        let current = Dictionary(counters.map { ($0.registryID, $0) }, uniquingKeysWith: { _, latest in latest })
        defer { previous = current }
        var rates: [EnergyProcessID: ProcessUsage] = [:]
        for counter in current.values {
            guard let old = previous[counter.registryID], counter.process == old.process,
                  counter.queueCount == old.queueCount, counter.nanoseconds >= old.nanoseconds else { continue }
            let elapsed = counter.uptime - old.uptime
            guard elapsed.isFinite, elapsed > 0 else { continue }
            let value = Double(counter.nanoseconds - old.nanoseconds) / 1e9 / elapsed * 100
            rates[counter.process] = ProcessUsage(id: counter.process, name: counter.name,
                primary: (rates[counter.process]?.primary ?? 0) + value)
        }
        return ProcessListReading(processes: Array(rates.values), message: counters.isEmpty ?
            L10n.text("이 Mac에서 프로세스별 GPU 통계를 제공하지 않습니다.") : rates.isEmpty ? L10n.text("다음 GPU 프로세스 측정을 기다리는 중") : nil)
    }
}

/// Optional Apple Silicon driver data, not a stable public schema. Never substitute CPU usage.
struct GPUProcessCollector {
    private var state = GPUProcessState()
    mutating func reset() { state.reset() }
    mutating func collect(processes: [ProcessResourceCounter]) throws -> ProcessListReading {
        let byPID = Dictionary(processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) == KERN_SUCCESS else {
            state.reset(); throw CollectionError.system(L10n.text("GPU 프로세스 통계를 읽을 수 없습니다."))
        }
        defer { IOObjectRelease(services) }
        var counters: [GPUClientCounter] = []
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard IOObjectConformsTo(client, "AGXDeviceUserClient") != 0,
                      let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, nil, 0)?.takeRetainedValue() as? String,
                      creator.hasPrefix("pid "), let pidText = creator.dropFirst(4).split(separator: ",").first,
                      let pid = Int32(pidText), let process = byPID[pid],
                      let usages = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]],
                      !usages.isEmpty else { continue }
                var total: UInt64 = 0, valid = true
                for usage in usages {
                    guard let number = usage["accumulatedGPUTime"] as? NSNumber, number.doubleValue >= 0 else { valid = false; break }
                    let sum = total.addingReportingOverflow(number.uint64Value)
                    guard !sum.overflow else { valid = false; break }
                    total = sum.partialValue
                }
                var id: UInt64 = 0
                guard valid, IORegistryEntryGetRegistryEntryID(client, &id) == KERN_SUCCESS else { continue }
                counters.append(GPUClientCounter(registryID: id, process: process.id, name: process.name,
                    queueCount: usages.count, nanoseconds: total, uptime: ProcessInfo.processInfo.systemUptime))
            }
        }
        return state.sample(counters)
    }
}
