import LookoutCore
import SwiftUI

private struct ActivityRateBasisKey: EnvironmentKey {
    static let defaultValue = ActivityRateBasis.data
}
extension EnvironmentValues {
    var activityRateBasis: ActivityRateBasis {
        get { self[ActivityRateBasisKey.self] }
        set { self[ActivityRateBasisKey.self] = newValue }
    }
}

struct ActivityRatePicker: View {
    let metric: Metric
    @ObservedObject var settings: SettingsStore
    private var title: String { L10n.text("\(metric.title) 표시 기준") }
    var body: some View {
        Menu {
            Picker(title, selection: Binding(
                get: { settings.configuration.rateBasis(for: metric) },
                set: { settings.setRateBasis($0, for: metric) }
            )) {
                ForEach(ActivityRateBasis.allCases) { Text($0.title(for: metric)).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Text(settings.configuration.rateBasis(for: metric).title(for: metric))
        }
        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.visible).controlSize(.mini)
        .font(.system(size: 10)).fixedSize()
        .disabled(!settings.configuration.enabled.contains(metric))
        .accessibilityLabel(title)
        .help(metric == .network ? L10n.text("표시 기준: 데이터 전송량 또는 초당 패킷 수") :
              L10n.text("표시 기준: 데이터 전송량 또는 초당 읽기·쓰기 작업 수"))
    }
}
