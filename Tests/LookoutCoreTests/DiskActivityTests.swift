import Foundation
@testable import LookoutCore
import Testing

private func counter(_ time: Double, id: UInt64 = 1, read: UInt64 = 100, write: UInt64 = 200) -> DiskCounter {
    DiskCounter(devices: [DiskDeviceCounter(id: id, read: read, write: write)], uptime: time)
}
@Test func storagePollingChangesInvalidateCacheAndDiskActivityRemainsIndependent() {
    var state = DiskSamplingState(), capacityCalls = 0, activityCalls = 0
    func sample(_ time: Double, interval: Int = 300, capacity: Bool = true, activity: Bool = false) -> DiskReading {
        state.sample(uptime: time, date: Date(timeIntervalSince1970: time), readCapacity: {
            capacityCalls += 1
            return DiskReading(name: "Data", total: 1000, available: Double(capacityCalls * 100))
        }, readCounters: {
            activityCalls += 1; return counter(time)
        }, collectActivity: activity, collectCapacity: capacity, capacityInterval: interval)
    }
    #expect(sample(0).capacity?.pollingInterval == 300)
    _ = sample(30); _ = sample(299)
    #expect(capacityCalls == 1 && activityCalls == 0)
    #expect(sample(300).capacity?.available == 200 && capacityCalls == 2)
    #expect(sample(301, interval: 600).capacity?.available == 300 && capacityCalls == 3)
    let io = sample(302, interval: 600, capacity: false, activity: true)
    #expect(io.capacity == nil && capacityCalls == 3 && activityCalls == 1)
    #expect(sample(303, interval: 600, capacity: false, activity: true).activity?.read == 0)
    #expect(sample(304, interval: 600).capacity?.available == 400 && capacityCalls == 4)
    #expect(sample(305, interval: 1800).capacity?.pollingInterval == 1800 && capacityCalls == 5)
    _ = sample(2104, interval: 1800, activity: true)
    #expect(capacityCalls == 5 && activityCalls == 3)
    #expect(sample(2105, interval: 1800).capacity?.available == 600 && capacityCalls == 6)
}

@Test func storageCapacityIncludesReclaimableSpaceWithValidFallback() throws {
    let available = try SystemMetrics.availableStorageCapacity(total: 1000, free: 100, important: 300)
    let disk = DiskReading(name: "Data", total: 1000, available: available)
    #expect(disk.available == 300 && disk.used == 700 && disk.percent == 70)
    for important: Int64? in [nil, -1, 1001, 50] {
        #expect(try SystemMetrics.availableStorageCapacity(total: 1000, free: 100, important: important) == 100)
    }
    #expect(try SystemMetrics.availableStorageCapacity(total: 1000, free: nil, important: 300) == 300)
    #expect(try SystemMetrics.availableStorageCapacity(total: 1000, free: 0, important: 0) == 0)
    #expect(throws: CollectionError.self) {
        try SystemMetrics.availableStorageCapacity(total: 1000, free: nil, important: nil)
    }
    #expect(throws: CollectionError.self) {
        try SystemMetrics.availableStorageCapacity(total: 1000, free: -1, important: 2000)
    }
    #expect(throws: CollectionError.self) {
        try SystemMetrics.availableStorageCapacity(total: 0, free: 0, important: 0)
    }
}
@Test func diskRatesUseRealElapsedTimeAndResetOnDeviceOrCounterChanges() {
    let first = counter(10)
    let next = counter(12.5, read: 1100, write: 2200)
    #expect(next.rate(since: first)?.read == 400)
    #expect(next.rate(since: first)?.write == 800)
    #expect(counter(12).rate(since: first)?.read == 0)
    #expect(counter(10).rate(since: first) == nil)
    #expect(counter(.infinity).rate(since: first) == nil)
    #expect(counter(12, id: 2).rate(since: first) == nil)
    #expect(counter(12, read: 99).rate(since: first) == nil)
    #expect(counter(12, write: 199).rate(since: first) == nil)
    let duplicate = DiskCounter(devices: first.devices + first.devices, uptime: 12)
    #expect(duplicate.rate(since: first) == nil)
    let multiple = DiskCounter(devices: [DiskDeviceCounter(id: 2, read: 500, write: 300)] + first.devices, uptime: 10)
    let later = DiskCounter(devices: next.devices + [DiskDeviceCounter(id: 2, read: 1000, write: 800)], uptime: 12.5)
    #expect(later.rate(since: multiple)?.read == 600)
    #expect(later.rate(since: multiple)?.write == 1000)
}
@Test func diskCapacitySamplesEveryThirtySecondsAndResetInvalidatesBothBaselines() {
    var state = DiskSamplingState(), calls = 0
    func capacity() -> DiskReading { calls += 1; return DiskReading(name: "Data", total: 1000, available: Double(calls * 100)) }
    func sample(_ time: Double) -> DiskReading {
        state.sample(uptime: time, date: Date(timeIntervalSince1970: time), readCapacity: capacity, readCounters: { counter(time) })
    }
    #expect(sample(0).activity == nil)
    #expect(sample(2).activity?.read == 0)
    #expect(sample(29).available == 100)
    #expect(calls == 1)
    #expect(sample(30).available == 200)
    #expect(calls == 2)
    state.reset()
    #expect(sample(31).activity == nil)
    #expect(calls == 3)
}
@Test func diskFailuresDoNotHideOtherDataOrReuseFailedCountersAndCapacity() {
    var state = DiskSamplingState()
    let date = Date()
    let capacity = { DiskReading(name: "Data", total: 1000, available: 200) }
    _ = state.sample(uptime: 0, date: date, readCapacity: capacity, readCounters: { counter(0) })
    let failedIO = state.sample(uptime: 2, date: date, readCapacity: capacity, readCounters: { throw CollectionError.system("I/O unavailable") })
    #expect(failedIO.capacity != nil)
    #expect(failedIO.activity == nil)
    #expect(failedIO.activityMessage == "I/O unavailable")
    #expect(state.sample(uptime: 4, date: date, readCapacity: capacity, readCounters: { counter(4) }).activity == nil)
    let failedCapacity = state.sample(uptime: 30, date: date, readCapacity: { throw CollectionError.system("Capacity unavailable") }, readCounters: { counter(30) })
    #expect(failedCapacity.capacity == nil)
    #expect(failedCapacity.activity?.read == 0)
    #expect(failedCapacity.capacityMessage == "Capacity unavailable")
    #expect(state.sample(uptime: 60, date: date, readCapacity: capacity, readCounters: { counter(60) }).capacity != nil)
}
@Test func memoryStorageSharesCapacityCacheWithoutReadingDisabledDiskActivity() {
    var state = DiskSamplingState(), capacityCalls = 0, activityCalls = 0
    func sample(_ time: Double, activity: Bool) -> DiskReading {
        state.sample(uptime: time, date: Date(timeIntervalSince1970: time), readCapacity: {
            capacityCalls += 1
            return DiskReading(name: "Data", total: 1000, available: Double(capacityCalls * 100))
        }, readCounters: {
            activityCalls += 1
            return counter(time)
        }, collectActivity: activity)
    }
    let first = sample(0, activity: false)
    #expect(first.capacity?.used == 900 && first.capacity?.available == 100)
    #expect(first.activity == nil && first.activityMessage == nil)
    #expect(sample(2, activity: false).capacity?.sampledAt == first.capacity?.sampledAt)
    #expect(capacityCalls == 1 && activityCalls == 0)
    #expect(sample(4, activity: true).activity == nil)
    #expect(sample(6, activity: true).activity?.read == 0)
    #expect(capacityCalls == 1 && activityCalls == 2)
    #expect(sample(8, activity: false).activity == nil)
    #expect(activityCalls == 2)
    // Re-enabling I/O starts a fresh baseline, while capacity remains shared.
    #expect(sample(10, activity: true).activity == nil)
    #expect(sample(30, activity: false).capacity?.available == 200)
    #expect(capacityCalls == 2 && activityCalls == 3)
}

@Test func unavailableSSDDoesNotHideMemoryUsageOrReuseOldCapacity() {
    var state = DiskSamplingState()
    _ = state.sample(uptime: 0, date: Date(), readCapacity: {
        DiskReading(name: "Data", total: 1000, available: 200)
    }, readCounters: { counter(0) }, collectActivity: false)
    let failed = state.sample(uptime: 30, date: Date(), readCapacity: {
        throw CollectionError.system("SSD unavailable")
    }, readCounters: { counter(30) }, collectActivity: false)
    let memory = MemoryReading(total: 1000, app: 400, wired: 200, compressed: 100, swap: nil)
    #expect(memory.used == 700 && memory.percent == 70)
    #expect(failed.capacity == nil && failed.capacityMessage == "SSD unavailable")
    #expect(ReadingValue.memory(memory).primary == 70)
}

@Test func diskHistoryTracksTwoRatesAndLeavesGapsWithoutActivity() {
    var history = HistoryBuffer()
    let end = Date(timeIntervalSince1970: 1000)
    let capacity = DiskCapacityReading(name: "Data", total: 1000, available: 200)
    func add(_ offset: Double, _ activity: DiskActivityReading?) {
        history.append(MetricReading(metric: .disk, date: end.addingTimeInterval(offset), value: .disk(DiskReading(capacity: capacity, activity: activity))), interval: 2)
    }
    add(-6, DiskActivityReading(read: 2000, write: 8000)); add(-4, nil); add(-2, DiskActivityReading(read: 0, write: 0)); add(0, DiskActivityReading(read: 0, write: 0))
    #expect(history.points[0].primary == 2000)
    #expect(history.points[0].secondary == 8000)
    #expect(history.points[1].primary == nil)
    #expect(history.points[0].segment != history.points[2].segment)
    #expect(history.points[2].primary == 0)
    #expect(ChartData.rateUpperBound(history: history.points) == 8000)
    #expect(ChartStyle.automatic.resolved(for: .disk) == .line)
}
@Test func diskAlertsRequireFreshCapacityConfirmationAndKeepCapacityScope() {
    var engine = AlertEngine()
    var rule = AlertRule(metric: .ssd, threshold: 20, duration: 10)
    rule.enabled = true
    let config = AlertConfiguration(rules: [rule])
    func evaluate(_ now: Double, observed: Double, free: Double?) {
        let capacity = free.map { DiskCapacityReading(name: "Data", total: 1e12, available: $0 * 1e9,
            sampledAt: Date(timeIntervalSince1970: observed), uptime: observed) }
        engine.evaluate([MetricReading(metric: .ssd, date: Date(timeIntervalSince1970: now),
            value: capacity.map(ReadingValue.storage))],
            configuration: config, monitored: [.ssd], uptime: now, interval: 2)
    }
    evaluate(0, observed: 0, free: 10)
    evaluate(12, observed: 0, free: 10)
    #expect(engine.active.isEmpty)
    evaluate(30, observed: 30, free: 10)
    #expect(engine.active.count == 1)
    #expect(engine.active.first?.value == 10)
    #expect(engine.active.first?.observedAt == Date(timeIntervalSince1970: 30))
    evaluate(60, observed: 60, free: nil)
    #expect(engine.notificationEligibleIDs.isEmpty)
    #expect(engine.active.count == 1)
    evaluate(90, observed: 90, free: 30)
    evaluate(102, observed: 90, free: 30)
    #expect(engine.active.count == 1)
    evaluate(120, observed: 120, free: 30)
    #expect(engine.active.isEmpty)
}
