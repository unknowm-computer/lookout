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
            HStack(spacing: 14) {
                rate("읽기", disk?.activity?.read, color)
                rate("쓰기", disk?.activity?.write, .orange)
            }
            if style == .bar {
                HistoryBarChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
                Text("최근 5분 · 5초 평균").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                if style == .gauge {
                    let upper = ChartData.rateUpperBound(history: history, current: reading?.value)
                    HStack(spacing: 14) {
                        rateGauge(disk?.activity?.read, upper: upper, tint: color)
                        rateGauge(disk?.activity?.write, upper: upper, tint: .orange)
                    }
                }
                Text("최근 5분 기록").font(.system(size: 9)).foregroundStyle(.secondary)
                MetricChart(metric: .disk, history: history, end: end, color: color).frame(height: 66)
            }
            if let message = disk?.activityMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let capacity = disk?.capacity {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("저장공간").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(ValueFormat.storage(capacity.used)) / \(ValueFormat.storage(capacity.total))").monospacedDigit()
                    }.font(.system(size: 10))
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.16))
                            Capsule().fill(color.opacity(0.65)).frame(width: geometry.size.width * capacity.percent / 100)
                        }
                    }.frame(height: 6).accessibilityLabel("저장공간 사용률")
                        .accessibilityValue(ValueFormat.percent(capacity.percent))
                    HStack {
                        Text("여유 \(ValueFormat.storage(capacity.available))").monospacedDigit()
                        Spacer()
                        Text("30초마다 갱신")
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(.top, 3)
            } else {
                Text(disk?.capacityMessage ?? "저장공간을 측정하는 중").font(.system(size: 9)).foregroundStyle(.secondary)
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
