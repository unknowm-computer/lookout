import LookoutCore
import SwiftUI
import UserNotifications

struct AlertSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notifications: NotificationService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notifications.permissionDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button(notifications.authorization == .notDetermined ? "알림 허용…" : "권한 확인") {
                            Task {
                                if notifications.authorization == .notDetermined { await notifications.requestAuthorization() }
                                else { await notifications.refreshAuthorization() }
                            }
                        }
                        Button("테스트 알림") { Task { await notifications.test(sound: settings.alerts.sound) } }
                        Spacer()
                        Toggle("소리", isOn: Binding(get: { settings.alerts.sound }, set: { settings.setAlertSound($0) }))
                            .toggleStyle(.checkbox)
                    }.disabled(notifications.busy)
                    if let feedback = notifications.feedback {
                        Text(feedback).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                ForEach(AlertConfiguration.supportedMetrics) { metric in
                    AlertRuleView(metric: metric, settings: settings, notifications: notifications)
                }
                Text("같은 문제는 한 번만 알립니다. 정상 범위가 10초 유지된 뒤 다시 발생하면 새 알림을 보냅니다. 측정 실패와 잠자기 시간은 제외합니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.trailing, 3)
        }
        .task { await notifications.refreshAuthorization() }
    }
}

private struct AlertRuleView: View {
    let metric: Metric
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notifications: NotificationService
    private var rule: AlertRule { settings.alerts.rule(for: metric) }
    private var monitored: Bool { settings.configuration.enabled.contains(metric) }
    private var title: String {
        switch metric { case .disk: "디스크 여유 공간"; default: "\(metric.title) 사용률" }
    }
    private var threshold: Binding<Double> {
        Binding(get: { rule.threshold }, set: { value in settings.updateAlert(metric) { $0.threshold = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: metric.symbol).frame(width: 18).foregroundStyle(.secondary)
                Toggle(title, isOn: Binding(get: { rule.enabled }, set: { enabled in
                    settings.updateAlert(metric) { $0.enabled = enabled }
                    if enabled && notifications.authorization == .notDetermined {
                        Task { await notifications.requestAuthorization() }
                    }
                })).toggleStyle(.checkbox)
            }
            HStack(spacing: 5) {
                Text("기준")
                TextField("\(title) 기준", value: threshold, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 53).multilineTextAlignment(.trailing)
                Stepper("\(title) 기준", value: threshold, in: rule.thresholdRange, step: 1)
                    .labelsHidden().fixedSize()
                Text("\(rule.unit) \(rule.condition)")
                Spacer(minLength: 4)
                Picker("\(title) 지속 시간", selection: Binding(get: { rule.duration }, set: { value in
                    settings.updateAlert(metric) { $0.duration = value }
                })) {
                    ForEach(durations, id: \.self) { duration in
                        Text(duration == 0 ? "즉시" : "\(Int(duration))초 유지").tag(duration)
                    }
                }.labelsHidden().frame(width: 105)
            }.disabled(!rule.enabled)
            Text(monitored ? "\(rule.recoveryDescription)" : "모니터링 꺼짐 · 알림 판단 일시 중지")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(11).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    private var durations: [Double] { Array(Set([0, 10, 30, 60, 120, rule.duration])).sorted() }
}
