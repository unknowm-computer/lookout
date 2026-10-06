import Foundation
import LookoutCore
import Testing

@Test func memoryChartChoicesRecoverLegacyLineWithoutChangingOtherMetrics() {
    #expect(ChartStyle.available(for: .memory) == [.automatic, .bar, .gauge])
    #expect(ChartStyle.available(for: .cpu).contains(.line))
    let saved = ChartPreferences(styles: ["memory": "line", "cpu": "line", "network": "gauge"])
    #expect(saved.style(for: .memory) == .automatic)
    #expect(saved.normalized.styles["memory"] == nil)
    #expect(saved.normalized.style(for: .cpu) == .line)
    #expect(saved.normalized.style(for: .network) == .gauge)
    #expect(ChartStyle.line.resolved(for: .memory) == .bar)
    var preferences = saved.normalized
    preferences.set(.gauge, for: .memory)
    #expect(preferences.style(for: .memory) == .gauge)
    preferences.set(.line, for: .memory)
    #expect(preferences.style(for: .memory) == .automatic)
}

@Test func graphSettingsRecoverUnknownValuesAndKeepOtherSelections() throws {
    let data = Data(#"{"styles":{"cpu":"bar","memory":"future","network":"line","future":"gauge"}}"#.utf8)
    var preferences = try JSONDecoder().decode(ChartPreferences.self, from: data).normalized
    #expect(preferences.style(for: .cpu) == .bar)
    #expect(preferences.style(for: .network) == .line)
    #expect(preferences.style(for: .memory) == .automatic)
    #expect(preferences.styles["future"] == nil)
    preferences.set(.gauge, for: .disk)
    preferences.set(.automatic, for: .cpu)
    #expect(preferences.styles["cpu"] == nil)
    #expect(preferences.style(for: .disk) == .gauge)
    #expect(try JSONDecoder().decode(ChartPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
}

@Test func barHistoryUsesTimeBinsMeanAndPreservesActualZero() {
    var history = HistoryBuffer()
    let end = Date(timeIntervalSince1970: 1000)
    for (seconds, value) in [(-10.0, 20.0), (-8, 40), (0, 0)] {
        history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(seconds), value: .cpu(value)), interval: 5)
    }
    let bars = ChartData.bars(history: history.points, end: end)
    #expect(bars.count == 60)
    #expect(bars[58].primary == 30)
    #expect(bars[59].primary == 0)
    #expect(bars[57].primary == nil)
    #expect(ChartData.bars(history: history.points, end: end.addingTimeInterval(301)).allSatisfy { $0.primary == nil })
    #expect(ChartData.bars(history: [], end: end, count: 0).isEmpty)
}

@Test func barHistoryDoesNotBridgeMissingSamplesOrContinuityChanges() {
    var history = HistoryBuffer()
    let end = Date(timeIntervalSince1970: 1000)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-3), value: .cpu(50)), interval: 2)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-2), value: nil), interval: 2)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-1), value: .cpu(0)), interval: 2)
    #expect(ChartData.bars(history: history.points, end: end)[59].primary == nil)
    var resumed = HistoryBuffer()
    resumed.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-3), value: .cpu(50)), interval: 2)
    resumed.breakContinuity()
    resumed.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-1), value: .cpu(10)), interval: 2)
    #expect(ChartData.bars(history: resumed.points, end: end)[59].primary == nil)
}

@Test func networkBarsAndGaugesUseSharedRateScaleInsteadOfPercent() {
    let end = Date(timeIntervalSince1970: 1000)
    var history = HistoryBuffer()
    for (offset, download, upload) in [(-2.0, 1000.0, 4000.0), (0, 3000, 8000)] {
        history.append(MetricReading(metric: .network, date: end.addingTimeInterval(offset),
                                    value: .network(NetworkReading(interface: "en0", download: download, upload: upload))), interval: 2)
    }
    let last = ChartData.bars(history: history.points, end: end)[59]
    #expect(last.primary == 2000)
    #expect(last.secondary == 6000)
    #expect(ChartData.rateUpperBound(history: history.points) == 8000)
    #expect(ChartData.rateUpperBound(history: [], current: .network(NetworkReading(interface: "en0", download: 1300, upload: 0))) == 2000)
    #expect(ChartData.rateUpperBound(history: []) == 1000)
}

@Test func gaugeAverageWeightsActualElapsedTimeAcrossIntervalChanges() {
    let end = Date(timeIntervalSince1970: 1000)
    var history = HistoryBuffer()
    for (offset, value) in [(-6.0, 0.0), (-5, 100), (0, 100)] {
        history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(offset), value: .cpu(value)), interval: 5)
    }
    let statistics = ChartData.usageStatistics(history: history.points, end: end)
    #expect(abs((statistics.average ?? 0) - 550.0 / 6) < 0.0001)
    #expect(statistics.maximum == 100)
}

@Test func gaugeSummaryExcludesOldFutureMissingAndInvalidSamples() {
    let end = Date(timeIntervalSince1970: 1000)
    var history = HistoryBuffer()
    for (offset, value) in [(-300.0, 99.0), (-10, 20), (-8, 40), (-6, .nan), (-4, -1), (-2, 101), (1, 100)] {
        history.append(MetricReading(metric: .gpu, date: end.addingTimeInterval(offset), value: .gpu(GPUReading(name: "Test", utilization: value, renderer: nil, tiler: nil, sharedMemory: nil))), interval: 2)
    }
    let statistics = ChartData.usageStatistics(history: history.points, end: end)
    #expect(statistics.average == 30)
    #expect(statistics.maximum == 40)
}

@Test func gaugeSummaryKeepsZeroAndDoesNotAverageAcrossMissingOrSleep() {
    let end = Date(timeIntervalSince1970: 1000)
    var history = HistoryBuffer()
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-10), value: .cpu(100)), interval: 2)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-8), value: nil), interval: 2)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-6), value: .cpu(0)), interval: 2)
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-4), value: .cpu(0)), interval: 2)
    history.breakContinuity()
    history.append(MetricReading(metric: .cpu, date: end.addingTimeInterval(-2), value: .cpu(100)), interval: 2)
    let statistics = ChartData.usageStatistics(history: history.points, end: end)
    #expect(statistics.average == 0)
    #expect(statistics.maximum == 100)
    #expect(ChartData.usageStatistics(history: [], end: end).average == nil)
    #expect(ChartData.usageStatistics(history: [], end: end).maximum == nil)
    var initial = HistoryBuffer()
    initial.append(MetricReading(metric: .cpu, date: end, value: .cpu(0)), interval: 2)
    #expect(ChartData.usageStatistics(history: initial.points, end: end).average == 0)
    #expect(ChartData.usageStatistics(history: initial.points, end: end).maximum == 0)
}
