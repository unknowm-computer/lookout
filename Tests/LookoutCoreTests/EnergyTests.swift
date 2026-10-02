import Foundation
@testable import LookoutCore
import Testing

private func energyCounter(_ pid: Int32 = 1, started: UInt64 = 1, energy: UInt64, at time: Double) -> EnergyProcessCounter {
    EnergyProcessCounter(id: EnergyProcessID(pid: pid, started: started), name: "Process \(pid)", nanojoules: energy, uptime: time)
}
@Test func processEnergyUsesNanojouleDeltaAndActualElapsedTime() {
    let baseline = energyCounter(energy: 2_000_000_000, at: 10)
    #expect(energyCounter(energy: 7_000_000_000, at: 12.5).watts(since: baseline) == 2)
    #expect(energyCounter(energy: 2_000_000_000, at: 12).watts(since: baseline) == 0)
    #expect(energyCounter(energy: 1, at: 12).watts(since: baseline) == nil)
    #expect(energyCounter(energy: 7_000_000_000, at: 10).watts(since: baseline) == nil)
    #expect(energyCounter(energy: 7_000_000_000, at: .infinity).watts(since: baseline) == nil)
    #expect(energyCounter(2, energy: 7_000_000_000, at: 12).watts(since: baseline) == nil)
    #expect(energyCounter(started: 2, energy: 7_000_000_000, at: 12).watts(since: baseline) == nil)
}
@Test func energyRanksMeasuredProcessesWithoutDoubleCountingOrInventingNewProcessRates() {
    var state = EnergySamplingState()
    let initial = (1...7).map { energyCounter(Int32($0), energy: 1_000_000_000, at: 10) }
    #expect(state.sample(counters: initial, totalCount: 10, sleepPreventers: []).watts == nil)
    let current = (1...7).map { energyCounter(Int32($0), energy: UInt64($0 + 1) * 1_000_000_000, at: 12) }
    let first = state.sample(counters: current + [current[0], energyCounter(8, energy: 99_000_000_000, at: 12)], totalCount: 10, sleepPreventers: [])
    #expect(first.watts == 14)
    #expect(first.measuredCount == 7)
    #expect(first.readableCount == 8)
    #expect(first.totalCount == 10)
    #expect(first.processes.map(\.id.pid) == [7, 6, 5, 4, 3])
    #expect(first.sleepPreventers?.isEmpty == true)
}
@Test func energyMissingProcessesAndResetBreakTheirBaselinesButKeepValidZero() {
    var state = EnergySamplingState()
    _ = state.sample(counters: [energyCounter(energy: 1_000_000_000, at: 0)], totalCount: 1, sleepPreventers: nil)
    let idle = state.sample(counters: [energyCounter(energy: 1_000_000_000, at: 2)], totalCount: 1, sleepPreventers: nil)
    #expect(idle.watts == 0 && idle.processes.isEmpty && idle.sleepPreventers == nil)
    #expect(state.sample(counters: [], totalCount: 1, sleepPreventers: []).watts == nil)
    #expect(state.sample(counters: [energyCounter(energy: 9_000_000_000, at: 4)], totalCount: 1, sleepPreventers: []).watts == nil)
    state.reset()
    #expect(state.sample(counters: [energyCounter(energy: 10_000_000_000, at: 6)], totalCount: 1, sleepPreventers: []).watts == nil)
    let unsupported = state.sample(counters: [energyCounter(energy: 11_000_000_000, at: 8)], totalCount: 1, sleepPreventers: [], supported: false)
    #expect(unsupported.watts == nil && unsupported.message != nil)
    #expect(unsupported.sleepPreventers?.isEmpty == true)
}
@Test func sleepPreventionExcludesDisplayAndInactiveAssertions() {
    #expect(EnergyCollector.isSleepPreventingAssertion(type: "PreventUserIdleSystemSleep", level: 255))
    #expect(EnergyCollector.isSleepPreventingAssertion(type: "PreventSystemSleep", level: 255))
    #expect(EnergyCollector.isSleepPreventingAssertion(type: "NoIdleSleepAssertion", level: 255))
    #expect(!EnergyCollector.isSleepPreventingAssertion(type: "PreventUserIdleDisplaySleep", level: 255))
    #expect(!EnergyCollector.isSleepPreventingAssertion(type: "PreventSystemSleep", level: 0))
    #expect(!EnergyCollector.isSleepPreventingAssertion(type: nil, level: 255))
    #expect(!EnergyCollector.isSleepPreventingAssertion(type: "PreventSystemSleep", level: nil))
}
@Test func energyHistoryUsesWattsWithAutomaticScaleAndMissingSamples() {
    var history = HistoryBuffer()
    let date = Date()
    history.append(MetricReading(metric: .power, date: date, value: .power(PowerReading(watts: 125))), interval: 2)
    history.append(MetricReading(metric: .power, date: date.addingTimeInterval(2), value: .power(PowerReading(watts: nil))), interval: 2)
    history.append(MetricReading(metric: .power, date: date.addingTimeInterval(4), value: .power(PowerReading(watts: 0))), interval: 2)
    #expect(history.points.first?.primary == 125)
    #expect(history.points[1].primary == nil)
    #expect(history.points.last?.primary == 0)
    #expect(history.points.first?.segment != history.points.last?.segment)
    #expect(ChartData.energyUpperBound(history: history.points) == 200)
    #expect(ChartData.energyUpperBound(history: [], current: .nan) == 1)
    #expect(ChartStyle.automatic.resolved(for: .power) == .line)
    #expect(ValueFormat.watts(1.23) == "1.2 W")
    #expect(ValueFormat.watts(0.01) == "<0.1 W")
    #expect(ValueFormat.watts(0) == "0.0 W")
}
