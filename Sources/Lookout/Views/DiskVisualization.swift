import LookoutCore
import SwiftUI

struct DiskVisualization: View {
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let style: ChartStyle
    let color: Color
    private var disk: DiskReading? { if case .disk(let value) = reading?.value { return value }; return nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .bar {
                Text("5초 평균").font(.system(size: 9)).foregroundStyle(.secondary)
                HistoryBarChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
            } else {
                MetricChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
            }
            HStack(spacing: 14) {
                rate("읽기", disk?.activity?.read, color)
                rate("쓰기", disk?.activity?.write, .orange)
            }
            if style == .gauge {
                let upper = ChartData.rateUpperBound(history: history, current: reading?.value)
                HStack(spacing: 14) {
                    rateGauge(disk?.activity?.read, upper: upper, tint: color)
                    rateGauge(disk?.activity?.write, upper: upper, tint: .orange)
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
            Text(value.map(ValueFormat.rate) ?? "—").monospacedDigit().fontWeight(.medium)
        }.font(.system(size: 11)).frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel("디스크 \(label) 속도")
            .accessibilityValue(value.map(ValueFormat.rate) ?? "측정값 없음")
    }
    private func rateGauge(_ value: Double?, upper: Double, tint: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                if let value { Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0, value / upper))) }
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}
