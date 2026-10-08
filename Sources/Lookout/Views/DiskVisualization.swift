import LookoutCore
import SwiftUI

struct DiskVisualization: View {
    @Environment(\.activityRateBasis) private var rateBasis
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let style: ChartStyle
    let color: Color
    var initiallyExpanded = false
    private var disk: DiskReading? { if case .disk(let value) = reading?.value { return value }; return nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .gauge {
                RateGaugeHistory(metric: .disk, reading: reading, history: history, end: end, color: color,
                                 initiallyExpanded: initiallyExpanded)
            } else {
                if style == .bar {
                    HistoryBarChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
                } else {
                    MetricChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
                }
                HStack(spacing: 14) {
                    rate(L10n.text("읽기"), disk?.activity?.read, color)
                    rate(L10n.text("쓰기"), disk?.activity?.write, .orange)
                }
            }
            if let message = disk?.activityMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func rate(_ label: String, _ value: Double?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.map { rateBasis.format($0, for: .disk) } ?? "—").monospacedDigit().fontWeight(.medium)
        }.font(.system(size: 11)).frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("디스크 \(label) 속도"))
            .accessibilityValue(value.map { rateBasis.format($0, for: .disk) } ?? L10n.text("측정값 없음"))
    }
}
