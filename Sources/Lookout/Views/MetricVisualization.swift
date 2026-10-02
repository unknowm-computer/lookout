import LookoutCore
import SwiftUI

struct MetricVisualization: View {
    let metric: Metric
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let preference: ChartStyle
    let color: Color
    @State private var historyExpanded: Bool
    init(metric: Metric, reading: MetricReading?, history: [HistoryPoint], end: Date,
         preference: ChartStyle, color: Color) {
        self.metric = metric; self.reading = reading; self.history = history; self.end = end
        self.preference = preference; self.color = color
        _historyExpanded = State(initialValue: [.cpu, .gpu, .memory].contains(metric))
    }
    private var style: ChartStyle { preference.resolved(for: metric) }
    private var showsHistoryBars: Bool { style == .bar && [.cpu, .gpu, .network].contains(metric) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if metric == .disk {
                DiskVisualization(reading: reading, history: history, end: end, style: style, color: color)
            } else if metric == .power {
                EnergyVisualization(reading: reading, history: history, end: end, style: style, color: color)
            } else if style == .line {
                line
            } else if showsHistoryBars {
                HistoryBarChart(metric: metric, history: history, end: end, color: color).frame(height: (metric == .network || metric == .disk) ? 82 : 66)
                Text("최근 5분 · 5초 평균").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if style == .gauge && [.cpu, .gpu, .memory, .disk].contains(metric) {
                PercentGaugeHistory(metric: metric, value: reading?.value?.primary,
                                    history: history, end: end, color: color)
            } else {
                if style == .bar {
                    CurrentMetricBar(metric: metric, value: reading?.value, color: color)
                } else {
                    NetworkGauges(value: reading?.value, upper: ChartData.rateUpperBound(history: history, current: reading?.value), color: color)
                }
                // A current-value display never replaces access to the existing history.
                DisclosureGroup("최근 5분 기록", isExpanded: $historyExpanded) { line.padding(.top, 5) }
                    .font(.system(size: 10)).tint(.secondary)
            }
        }
    }
    private var line: some View {
        MetricChart(metric: metric, history: history, end: end, color: color).frame(height: 66)
    }
}

private struct PercentGaugeHistory: View {
    let metric: Metric
    let value: Double?
    let history: [HistoryPoint]
    let end: Date
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 14) {
                PercentGauge(value: value, color: color).frame(width: 108, height: 66)
                VStack(alignment: .leading, spacing: 5) {
                    Text("최근 5분 기록").font(.system(size: 9)).foregroundStyle(.secondary)
                    MetricChart(metric: metric, history: history, end: end, color: color).frame(height: 50)
                }.frame(maxWidth: .infinity)
            }
            GaugeUsageSummary(statistics: ChartData.usageStatistics(history: history, end: end))
        }
    }
}

private struct GaugeUsageSummary: View {
    let statistics: UsageStatistics
    var body: some View {
        HStack(spacing: 12) {
            Text("최근 5분").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            row("평균", statistics.average)
            row("최고", statistics.maximum)
        }
    }
    private func row(_ title: String, _ value: Double?) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(value.map(ValueFormat.percent) ?? "—").monospacedDigit().fontWeight(.medium)
                .frame(width: 34, alignment: .trailing)
        }.font(.system(size: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("최근 5분 \(title) 사용률")
            .accessibilityValue(value.map(ValueFormat.percent) ?? "측정값 없음")
    }
}

struct HistoryBarChart: View {
    let metric: Metric
    let history: [HistoryPoint]
    let end: Date
    let color: Color
    private var upper: Double { metric == .power ? ChartData.energyUpperBound(history: history) : (metric == .network || metric == .disk) ? ChartData.rateUpperBound(history: history) : 100 }
    var body: some View {
        let bound = upper, bars = ChartData.bars(history: history, end: end)
        HStack(spacing: 5) {
            Canvas(rendersAsynchronously: true) { context, size in
                let network = (metric == .network || metric == .disk)
                let center = network ? size.height / 2 : size.height
                var grid = Path()
                for y in [CGFloat(0.5), center, size.height - 0.5] {
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                let step = size.width / 60, availableHeight = network ? size.height / 2 - 1 : size.height - 1
                for bar in bars {
                    let x = CGFloat(bar.index) * step
                    if let value = bar.primary {
                        let height = availableHeight * min(1, max(0, value / bound))
                        context.fill(Path(CGRect(x: x, y: center - height, width: max(1, step - 1), height: height)), with: .color(color.opacity(0.85)))
                    }
                    if network, let value = bar.secondary {
                        let height = availableHeight * min(1, max(0, value / bound))
                        context.fill(Path(CGRect(x: x, y: center + 1, width: max(1, step - 1), height: height)), with: .color(.orange.opacity(0.85)))
                    }
                }
            }
            VStack(alignment: .trailing) {
                Text((metric == .network || metric == .disk) ? (metric == .disk ? "R " : "↓ ") + ValueFormat.rate(bound) : metric == .power ? ValueFormat.watts(bound) : "100")
                Spacer(minLength: 0)
                Text("0")
                if (metric == .network || metric == .disk) {
                    Spacer(minLength: 0)
                    Text((metric == .disk ? "W " : "↑ ") + ValueFormat.rate(bound))
                }
            }.font(.system(size: 8)).foregroundStyle(.secondary).frame(width: (metric == .network || metric == .disk || metric == .power) ? 59 : 22, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) 최근 5분 막대 그래프 · 5초 평균")
        .accessibilityValue(history.last?.primary.map { (metric == .network || metric == .disk) ? ValueFormat.rate($0) : metric == .power ? ValueFormat.watts($0) : ValueFormat.percent($0) } ?? "측정값 없음")
    }
}

private struct PercentGauge: View {
    let value: Double?
    let color: Color
    private var validValue: Double? { value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } }
    var body: some View {
        ZStack(alignment: .bottom) {
            Canvas(rendersAsynchronously: true) { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 5)
                let radius = min(size.width / 2 - 7, size.height - 12)
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                context.stroke(track, with: .color(.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                if let value = validValue, value > 0 {
                    var progress = Path()
                    progress.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + value * 1.8), clockwise: false)
                    context.stroke(progress, with: .color(color), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
            }
            Text(validValue.map(ValueFormat.percent) ?? "—").font(.system(size: 20, weight: .medium)).monospacedDigit().padding(.bottom, 3)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("현재 사용률 게이지")
        .accessibilityValue(validValue.map(ValueFormat.percent) ?? "측정값 없음")
    }
}

private struct CurrentMetricBar: View {
    let metric: Metric
    let value: ReadingValue?
    let color: Color
    private var segments: [(Double, Color)] {
        switch value {
        case .memory(let memory):
            guard memory.total > 0 else { return [] }
            return [(memory.app / memory.total, .purple), (memory.wired / memory.total, .cyan), (memory.compressed / memory.total, .orange)]
        default: return value?.primary.map { [($0 / 100, color)] } ?? []
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Canvas(rendersAsynchronously: true) { context, size in
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
                context.fill(shape, with: .color(.secondary.opacity(0.16)))
                context.clip(to: shape)
                var x: CGFloat = 0
                for (fraction, tint) in segments where fraction.isFinite {
                    let width = min(size.width - x, size.width * min(1, max(0, fraction)))
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(tint))
                    x += width
                }
            }.frame(height: 13)
            if case .memory = value {
                HStack(spacing: 12) {
                    legend("앱", .purple); legend("Wired", .cyan); legend("압축", .orange); legend("여유", .secondary.opacity(0.4))
                }
            } else {
                HStack {
                    Text(value?.primary.map { "사용 \(ValueFormat.percent($0))" } ?? "측정값 없음")
                    Spacer()
                    if case .disk(let disk) = value { Text("여유 \(ValueFormat.storage(disk.available))") }
                    else { Text("100%") }
                }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(metric.title) 현재 상태 막대")
        .accessibilityValue(accessibilitySummary)
    }
    private var accessibilitySummary: String {
        switch value {
        case .memory(let memory): return "앱 \(ValueFormat.memory(memory.app)), Wired \(ValueFormat.memory(memory.wired)), 압축 \(ValueFormat.memory(memory.compressed)), 사용률 \(ValueFormat.percent(memory.percent))"
        case .disk(let disk): return "사용 \(ValueFormat.storage(disk.used)), 여유 \(ValueFormat.storage(disk.available))"
        default: return value?.primary.map(ValueFormat.percent) ?? "측정값 없음"
        }
    }
    private func legend(_ title: String, _ tint: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(tint).frame(width: 5, height: 5); Text(title) }
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

private struct NetworkGauges: View {
    let value: ReadingValue?
    let upper: Double
    let color: Color
    private var network: NetworkReading? { if case .network(let network) = value { return network }; return nil }
    var body: some View {
        VStack(spacing: 7) {
            row("↓", network?.download, color)
            row("↑", network?.upload, .orange)
            Text("눈금 자동 · 최대 \(ValueFormat.rate(upper)) · 회선 용량 대비 비율이 아닙니다.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
    private func row(_ arrow: String, _ rate: Double?, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            HStack { Text(arrow).foregroundStyle(tint); Spacer(); Text(rate.map(ValueFormat.rate) ?? "—").monospacedDigit() }.font(.system(size: 10))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.16))
                    if let rate, rate.isFinite {
                        Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, rate / upper)))
                    }
                }
            }.frame(height: 6)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(arrow == "↓" ? "다운로드 속도 게이지" : "업로드 속도 게이지")
            .accessibilityValue(rate.map(ValueFormat.rate) ?? "측정값 없음")
    }
}
