import Foundation
import LookoutCore
import Testing

private func counter(_ time: Double, id: UInt64 = 1, read: UInt64 = 100, write: UInt64 = 200) -> DiskCounter {
    DiskCounter(devices: [DiskDeviceCounter(id: id, read: read, write: write)], uptime: time)
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
    var rule = AlertRule(metric: .disk, threshold: 20, duration: 10)
    rule.enabled = true
    let config = AlertConfiguration(rules: [rule])
    func evaluate(_ now: Double, observed: Double, free: Double?) {
        let capacity = free.map { DiskCapacityReading(name: "Data", total: 1e12, available: $0 * 1e9,
            sampledAt: Date(timeIntervalSince1970: observed), uptime: observed) }
        engine.evaluate([MetricReading(metric: .disk, date: Date(timeIntervalSince1970: now),
            value: .disk(DiskReading(capacity: capacity, activity: DiskActivityReading(read: 1e6, write: 1e6))))],
            configuration: config, monitored: [.disk], uptime: now, interval: 2)
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
