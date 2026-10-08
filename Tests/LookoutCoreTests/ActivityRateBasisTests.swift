import Foundation
@testable import LookoutCore
import Testing

@Test func packetRatesUsePacketCountersAndActualElapsedTime() {
    let first = NetworkCounter(name: "en0", received: 1000, sent: 500, uptime: 10,
                               receivedPackets: 100, sentPackets: 20)
    let next = NetworkCounter(name: "en0", received: 6000, sent: 1000, uptime: 12.5,
                              receivedPackets: 125, sentPackets: 30)
    #expect(next.rate(since: first)?.download == 2000)
    let packets = next.rate(since: first, basis: .count)
    #expect(packets?.download == 10 && packets?.upload == 4 && packets?.basis == .count)
    let reset = NetworkCounter(name: "en0", received: 7000, sent: 1000, uptime: 15,
                               receivedPackets: 1, sentPackets: 35)
    #expect(reset.rate(since: next, basis: .count) == nil)
    #expect(reset.rate(since: next, basis: .data) != nil)
    #expect(NetworkCounter(name: "en0", received: 6000, sent: 1000, uptime: 15).rate(since: first, basis: .count) == nil)
    #expect(NetworkCounter(name: "en0", received: 6000, sent: 1000, uptime: .infinity).rate(since: first) == nil)
}

@Test func diskOperationRatesStayIndependentOfBytesAndRejectMissingOrResetCounters() {
    func counter(_ time: Double, reads: UInt64?, writes: UInt64?, id: UInt64 = 1) -> DiskCounter {
        DiskCounter(devices: [DiskDeviceCounter(id: id, read: UInt64(time * 1000), write: UInt64(time * 2000),
                                               readOperations: reads, writeOperations: writes)], uptime: time)
    }
    let first = counter(10, reads: 50, writes: 100), next = counter(12.5, reads: 75, writes: 105)
    let activity = next.rate(since: first, basis: .count)
    #expect(activity?.read == 10 && activity?.write == 2 && activity?.basis == .count)
    #expect(next.rate(since: first)?.read == 1000)
    #expect(counter(15, reads: 1, writes: 110).rate(since: next, basis: .count) == nil)
    #expect(counter(15, reads: 90, writes: nil).rate(since: next, basis: .count) == nil)
    #expect(counter(15, reads: 90, writes: 110, id: 2).rate(since: next, basis: .count) == nil)
}

@Test func rateBasisSettingsRoundTripAndRecoverLegacyAndUnknownModes() throws {
    let legacy = try JSONDecoder().decode(SettingsRecord.self, from: Data(#"{"version":2,"interval":3}"#.utf8))
    #expect(legacy.configuration.networkRateBasis == .data && legacy.configuration.diskRateBasis == .data)
    let mixed = try JSONDecoder().decode(SettingsRecord.self, from: Data(#"{"version":2,"networkRateBasis":"future","diskRateBasis":"count"}"#.utf8))
    #expect(mixed.configuration.networkRateBasis == .data && mixed.configuration.diskRateBasis == .count)
    let configuration = MonitorConfiguration(networkRateBasis: .count, diskRateBasis: .data)
    let restored = try JSONDecoder().decode(SettingsRecord.self, from: JSONEncoder().encode(SettingsRecord(configuration: configuration)))
    #expect(restored.configuration == configuration)
}

@Test func operationFormattingAndGraphScalesDoNotUseByteUnits() {
    #expect(ActivityRateBasis.count.format(25, for: .network) == "25 pkt/s")
    #expect(ActivityRateBasis.count.format(1250, for: .disk) == "1.2k IO/s")
    #expect(ActivityRateBasis.data.format(1250, for: .disk) == ValueFormat.rate(1250))
    let current = ReadingValue.network(NetworkReading(interface: "en0", download: 12, upload: 25, basis: .count))
    #expect(ChartData.rateUpperBound(history: [], current: current, minimum: 1) == 30)
    #expect(ChartData.rateUpperBound(history: [], minimum: 1) == 1)
    #expect(ChartData.rateUpperBound(history: []) == 1000)
}
