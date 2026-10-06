import LookoutCore
import SwiftUI

struct MemoryMetricVisualization: View {
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let style: ChartStyle
    let showsSwapDetails: Bool
    @State private var historyExpanded = true
    private var memory: MemoryReading? {
        if case .memory(let memory) = reading?.value { return memory }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .gauge {
                PercentGaugeHistory(metric: .memory, value: memory?.percent,
                                    history: history, end: end, color: .purple,
                                    segments: memoryCompositionSegments(memory))
                if let memory { MemoryUsageDetails(memory: memory, showsSwapDetails: showsSwapDetails) }
            } else {
                MemoryCurrentBar(memory: memory)
                if let memory { MemoryUsageDetails(memory: memory, showsSwapDetails: showsSwapDetails) }
                DisclosureGroup("최근 5분 기록", isExpanded: $historyExpanded) {
                    historyChart.padding(.top, 5)
                }.font(.system(size: 10)).tint(.secondary)
            }
        }
    }
    private var historyChart: some View {
        MetricChart(metric: .memory, history: history, end: end, color: .purple).frame(height: 66)
    }
}

private enum MemoryComponent: CaseIterable, Identifiable {
    case app, wired, compressed, free
    var id: Self { self }
    var title: String {
        switch self {
        case .app: "앱"
        case .wired: "Wired"
        case .compressed: "압축"
        case .free: "여유"
        }
    }
    var color: Color {
        switch self {
        case .app: .purple
        case .wired: .cyan
        case .compressed: .orange
        case .free: .secondary.opacity(0.4)
        }
    }
    func bytes(in memory: MemoryReading) -> Double {
        switch self {
        case .app: memory.app
        case .wired: memory.wired
        case .compressed: memory.compressed
        case .free: max(0, memory.total - memory.used)
        }
    }
    func summary(in memory: MemoryReading) -> String {
        let bytes = bytes(in: memory)
        let percent = memory.total > 0 ? bytes / memory.total * 100 : 0
        return "\(title) · \(ValueFormat.memory(bytes)) · \(ValueFormat.percent(percent))"
    }
    func fraction(in memory: MemoryReading) -> Double {
        func bounded(_ component: Self) -> Double {
            let fraction = component.bytes(in: memory) / memory.total
            return fraction.isFinite ? min(1, max(0, fraction)) : 0
        }
        let preceding = Self.allCases.prefix(while: { $0 != self }).reduce(0) { $0 + bounded($1) }
        return min(bounded(self), max(0, 1 - preceding))
    }
}

private struct MemoryCurrentBar: View {
    let memory: MemoryReading?
    var body: some View {
        SegmentedUsageBar(segments: memoryCompositionSegments(memory), accessibilityTitle: "메모리 현재 상태 막대")
    }
}

private func memoryCompositionSegments(_ memory: MemoryReading?) -> [UsageBarSegment] {
    guard let memory, memory.total.isFinite, memory.total > 0 else { return [] }
    return MemoryComponent.allCases.map { component in
        UsageBarSegment(id: String(describing: component), title: component.title,
                        fraction: component.fraction(in: memory), color: component.color,
                        summary: component.summary(in: memory))
    }
}

private struct MemoryUsageDetails: View {
    let memory: MemoryReading
    let showsSwapDetails: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 4) {
                ForEach(MemoryComponent.allCases) { component in
                    HStack(spacing: 4) {
                        Circle().fill(component.color).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(component.title).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(ValueFormat.memory(component.bytes(in: memory))).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            SwapUsageBar(memory: memory, showsDetails: showsSwapDetails).padding(.top, 4)
        }.font(.system(size: 10))
    }
}

private struct SwapUsageBar: View {
    let memory: MemoryReading
    let showsDetails: Bool
    private let usedColor: Color = .teal
    private let freeColor: Color = .secondary.opacity(0.4)
    private var segments: [UsageBarSegment] {
        guard let percent = memory.swapPercent, let used = memory.swap,
              let available = memory.swapAvailable, let total = memory.swapTotal else { return [] }
        if total == 0 {
            return [UsageBarSegment(id: "unallocated", title: "Swap 할당 없음", fraction: 1, color: freeColor,
                                    summary: "현재 할당된 스왑 공간 없음 · 필요 시 macOS가 자동 할당")]
        }
        return [UsageBarSegment(id: "used", title: "Swap 사용", fraction: percent / 100, color: usedColor,
                                summary: "Swap 사용 · \(ValueFormat.memory(used)) · 현재 할당량의 \(ValueFormat.percent(percent))"),
                UsageBarSegment(id: "free", title: "Swap 할당 여유", fraction: 1 - percent / 100, color: freeColor,
                                summary: "Swap 할당 여유 · \(ValueFormat.memory(available)) · 현재 할당량의 \(ValueFormat.percent(100 - percent))")]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    if !showsDetails {
                        Circle().fill(usedColor).frame(width: 5, height: 5).accessibilityHidden(true)
                    }
                    Text("Swap").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(memory.swap.map(ValueFormat.memory) ?? "—") / \(memory.swapTotal.map(ValueFormat.memory) ?? "—")")
                    .monospacedDigit()
            }
            .help("사용량 / 현재 할당량입니다. macOS가 필요에 따라 자동으로 확장하며, 고정된 최대 용량은 아닙니다. RAM 구성 막대에는 포함되지 않습니다.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Swap 사용량 / 현재 할당량")
            .accessibilityValue("\(memory.swap.map(ValueFormat.memory) ?? "측정값 없음") / \(memory.swapTotal.map(ValueFormat.memory) ?? "측정값 없음")")
            if showsDetails {
                SegmentedUsageBar(segments: segments, accessibilityTitle: "Swap 현재 할당량 대비 사용 막대")
                HStack(spacing: 16) {
                    amount("사용", memory.swap, color: usedColor)
                    amount("할당 여유", memory.swapAvailable, color: freeColor)
                }
            }
        }
    }
    private func amount(_ title: String, _ bytes: Double?, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(bytes.map(ValueFormat.memory) ?? "—").monospacedDigit()
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}
