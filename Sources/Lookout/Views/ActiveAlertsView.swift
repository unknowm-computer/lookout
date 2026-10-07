import LookoutCore
import SwiftUI

struct ActiveAlertsView: View {
    let alerts: [AlertEvent]
    let readings: [Metric: MetricReading]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L10n.text("주의가 필요한 항목"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            ForEach(alerts) { alert in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(alert.title).fontWeight(.medium)
                        Spacer()
                        Text(alert.firstDetected, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                    Text(alert.message).foregroundStyle(.secondary)
                    if readings[alert.metric]?.value == nil {
                        Text(L10n.text("측정 확인 중 · 경고 상태 유지")).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.orange.opacity(0.08))
    }
}
