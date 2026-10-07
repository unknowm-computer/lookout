import LookoutCore
import SwiftUI

/// Both I/O metrics share current-speed gauges and an optional history chart.
struct RateGaugeHistory: View {
    let metric: Metric
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let color: Color
    let initiallyExpanded: Bool
    @State private var historyExpanded: Bool
    init(metric: Metric, reading: MetricReading?, history: [HistoryPoint], end: Date, color: Color,
         initiallyExpanded: Bool) {
        self.metric = metric; self.reading = reading; self.history = history; self.end = end; self.color = color
        self.initiallyExpanded = initiallyExpanded
        _historyExpanded = State(initialValue: initiallyExpanded)
    }

    private var rates: (first: Double?, second: Double?) {
        switch reading?.value {
        case .network(let value): (value.download, value.upload)
        case .disk(let value): (value.activity?.read, value.activity?.write)
        default: (nil, nil)
        }
    }
    private var upper: Double { ChartData.rateUpperBound(history: history, current: reading?.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(metric == .network ? L10n.text("다운로드") : L10n.text("읽기"), rates.first, color)
            row(metric == .network ? L10n.text("업로드") : L10n.text("쓰기"), rates.second, .orange)
            Text(L10n.text("눈금 자동 · 최대 \(ValueFormat.rate(upper))"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .help(L10n.text("현재 속도를 자동 눈금으로 표시합니다. 최대 처리 용량 대비 사용률이 아닙니다."))
            DisclosureGroup(L10n.text("최근 5분 기록"), isExpanded: $historyExpanded) {
                MetricChart(metric: metric, history: history, end: end, color: color)
                    .frame(height: 66).padding(.top, 5)
            }.font(.system(size: 10)).tint(.secondary)
        }.onChange(of: initiallyExpanded) { _, value in historyExpanded = value }
    }

    private func row(_ label: String, _ value: Double?, _ tint: Color) -> some View {
        let validValue = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(validValue.map(ValueFormat.rate) ?? "—").monospacedDigit().fontWeight(.medium)
            }.font(.system(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.16))
                    if let validValue {
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * min(1, max(0, validValue / upper)))
                    }
                }
            }.frame(height: 6)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("\(metric.title) \(label) 속도 게이지"))
            .accessibilityValue(validValue.map(ValueFormat.rate) ?? L10n.text("측정값 없음"))
    }
}
