import LookoutCore
import SwiftUI

struct EnergyVisualization: View {
    let reading: MetricReading?
    let history: [HistoryPoint]
    let end: Date
    let style: ChartStyle
    let color: Color
    private var energy: PowerReading? { if case .power(let value) = reading?.value { return value }; return nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .bar {
                HistoryBarChart(metric: .power, history: history, end: end, color: color).frame(height: 66)
            } else if style == .gauge {
                let upper = ChartData.energyUpperBound(history: history, current: energy?.watts)
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.16))
                            if let watts = energy?.watts {
                                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, watts / upper)))
                            }
                        }
                    }.frame(height: 6)
                    HStack {
                        Text("0 W")
                        Spacer()
                        Text(L10n.text("자동 눈금 · \(ValueFormat.watts(upper))"))
                    }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("에너지 현재 전력 게이지"))
                .accessibilityValue(energy?.watts.map(ValueFormat.watts) ?? L10n.text("측정값 없음"))
            } else {
                MetricChart(metric: .power, history: history, end: end, color: color).frame(height: 66)
            }
            if let message = energy?.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let energy, energy.watts != nil {
                Text(L10n.text("\(energy.measuredCount)/\(energy.totalCount)개 프로세스 측정 · Mac 전체 전력 아님"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Divider()
            SleepPreventersView(preventers: energy?.sleepPreventers)
        }
    }
}
