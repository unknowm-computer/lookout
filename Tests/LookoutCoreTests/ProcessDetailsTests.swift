import Foundation
@testable import LookoutCore
import Testing

private func resource(_ pid: Int32 = 1, start: UInt64 = 1, cpu: UInt64 = 0, system: UInt64 = 0,
                      memory: UInt64 = 1, read: UInt64 = 0, write: UInt64 = 0, at: Double) -> ProcessResourceCounter {
    ProcessResourceCounter(id: EnergyProcessID(pid: pid, started: start), name: "Process \(pid)",
                           userTime: cpu, systemTime: system, memory: memory, read: read, write: write, uptime: at)
}

@Test func processDetailsUseMachTimebaseAndActualIntervalWithoutClampingToOneCore() {
    var state = ProcessResourceState(nanosecondsPerTick: 125.0 / 3)
    let metrics: Set<Metric> = [.cpu, .memory, .disk]
    let first = state.sample([resource(cpu: 10, system: 10, memory: 42, read: 100, write: 200, at: 10)], metrics: metrics)
    #expect(first[.cpu]?.message != nil)
    #expect(first[.memory]?.processes.first?.primary == 42)
    let next = state.sample([resource(cpu: 72_000_010, system: 24_000_010, memory: 84, read: 300, write: 800, at: 12)], metrics: metrics)
    #expect(next[.cpu]?.processes.first?.primary == 200)
    #expect(next[.disk]?.processes.first?.primary == 100)
    #expect(next[.disk]?.processes.first?.secondary == 300)
}

@Test func processDetailsDropPIDReuseMissingProcessesAndResetCounters() {
    var state = ProcessResourceState(nanosecondsPerTick: 1)
    let metrics: Set<Metric> = [.cpu, .disk]
    _ = state.sample([resource(cpu: 100, read: 100, at: 0)], metrics: metrics)
    #expect(state.sample([resource(start: 2, cpu: 999, read: 999, at: 1)], metrics: metrics)[.cpu]?.processes.isEmpty == true)
    #expect(state.sample([resource(start: 2, cpu: 50, read: 50, at: 2)], metrics: metrics)[.disk]?.processes.isEmpty == true)
    _ = state.sample([], metrics: metrics)
    #expect(state.sample([resource(start: 2, cpu: 999, at: 4)], metrics: metrics)[.cpu]?.processes.isEmpty == true)
    state.reset()
    #expect(state.sample([resource(start: 2, cpu: 1999, at: 5)], metrics: metrics)[.cpu]?.processes.isEmpty == true)
    #expect(state.sample([resource(start: 2, cpu: 2999, at: 5)], metrics: metrics)[.cpu]?.processes.isEmpty == true)
}

@Test func processListsRankCombinedActivityCapFiveAndExcludeInvalidAndIdleValues() {
    let rows = (1...8).map { ProcessUsage(id: EnergyProcessID(pid: Int32($0), started: 1), name: "\($0)", primary: 1, secondary: Double($0)) }
    let invalid = [Double.nan, .infinity, -1, 0].enumerated().map {
        ProcessUsage(id: EnergyProcessID(pid: Int32(20 + $0.offset), started: 1), name: "invalid", primary: $0.element)
    }
    #expect(ProcessListReading(processes: rows + invalid).processes.map(\.id.pid) == [8, 7, 6, 5, 4])
    var state = ProcessResourceState(nanosecondsPerTick: 1)
    let sample = resource(cpu: 5, at: 1)
    _ = state.sample([sample, sample], metrics: [.cpu])
    let idle = state.sample([resource(cpu: 5, at: 2)], metrics: [.cpu])
    #expect(idle[.cpu]?.message == nil && idle[.cpu]?.processes.isEmpty == true)
    #expect(state.sample([sample], metrics: [.memory])[.cpu] == nil)
}

@Test func gpuProcessesAggregateClientsAndRejectClientReplacementAndQueueChanges() {
    func client(_ registry: UInt64, pid: Int32 = 1, start: UInt64 = 1, queues: Int = 1, ns: UInt64, at: Double) -> GPUClientCounter {
        GPUClientCounter(registryID: registry, process: EnergyProcessID(pid: pid, started: start), name: "GPU \(pid)",
                         queueCount: queues, nanoseconds: ns, uptime: at)
    }
    var state = GPUProcessState()
    #expect(state.sample([client(1, ns: 0, at: 0), client(2, ns: 0, at: 0)]).message != nil)
    let next = state.sample([client(1, ns: 1_000_000_000, at: 2), client(2, ns: 500_000_000, at: 2)])
    #expect(next.processes.count == 1 && next.processes.first?.primary == 75)
    let reset = state.sample([client(1, start: 2, ns: 2_000_000_000, at: 4), client(2, queues: 2, ns: 999_000_000, at: 4)])
    #expect(reset.processes.isEmpty)
    #expect(state.sample([]).message != nil)
    state.reset()
    #expect(state.sample([client(1, ns: 100, at: 6)]).processes.isEmpty)
}

@Test func networkProcessCSVUsesSecondFrameDeltasAndRealTimestampsAcrossMidnight() {
    let csv = """
    time,,bytes_in,bytes_out,
    23:59:59.000000,"App, Helper.123",900000,800000,
    23:59:59.000000,Idle.124,1000,2000,
    time,,bytes_in,bytes_out,
    00:00:01.000000,"App, Helper.123",2000,1000,
    00:00:01.000000,Idle.124,0,0,
    00:00:01.000000,New.125,99999999,999999,
    """
    let value = NetworkProcessCollector.parse(csv)
    #expect(value.message == nil)
    #expect(value.processes.count == 1)
    #expect(value.processes.first?.name == "App, Helper")
    #expect(value.processes.first?.primary == 1000)
    #expect(value.processes.first?.secondary == 500)
    #expect(NetworkProcessCollector.csv("\"Name \"\"quoted\"\".123\",1,2,")?.first == "Name \"quoted\".123")
    #expect(NetworkProcessCollector.parse(csv.replacingOccurrences(of: "00:00:01", with: "00:00:09")).message != nil)
    #expect(NetworkProcessCollector.parse("permission denied").message != nil)
    #expect(NetworkProcessCollector.parse("time,,bytes_in,bytes_out,\n12:00:00,A.1,1,1,").message != nil)
}

@Test func closedProcessDetailsReturnNoData() async {
    let sampler = ProcessDetailSampler()
    #expect(await sampler.collect([]).isEmpty)
    // Energy is reused from the main sampler, not sampled twice for the disclosure.
    #expect(await sampler.collect([.power]).isEmpty)
}
