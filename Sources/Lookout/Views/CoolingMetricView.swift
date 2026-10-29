import LookoutCore
import ServiceManagement
import SwiftUI

struct CoolingMetricView: View {
    let reading: CoolingReading?
    let history: [HistoryPoint]
    let end: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: Metric.cooling.symbol).foregroundStyle(reading?.band.tint ?? .secondary).frame(width: 16)
                Text(Metric.cooling.title).fontWeight(.semibold)
                Spacer()
                Text(reading?.temperature.map(ValueFormat.temperature) ?? "—")
                    .monospacedDigit().fontWeight(.medium).foregroundStyle(reading?.band.tint ?? .primary)
            }.font(.system(size: 12))
            if let reading {
                MetricChart(metric: .cooling, history: history, end: end, color: .cyan).frame(height: 66)
                HStack {
                    sensor(L10n.text("CPU 최고"), reading.cpu, color: .cyan)
                    Spacer()
                    sensor(L10n.text("GPU 최고"), reading.gpu, color: .orange)
                }.font(.system(size: 10))
                ForEach(reading.fans) { fan in
                    HStack {
                        Image(systemName: "fan").foregroundStyle(.secondary).frame(width: 16)
                        Text(fan.title)
                        Spacer()
                        Text(ValueFormat.rpm(fan.rpm)).monospacedDigit()
                    }.font(.system(size: 11))
                }
            } else {
                Text(L10n.text("온도와 팬 정보를 읽을 수 없습니다.")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func sensor(_ title: String, _ value: Double?, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Text(value.map(ValueFormat.temperature) ?? "—").monospacedDigit()
        }
    }
}

struct CoolingModePicker: View {
    @EnvironmentObject private var control: CoolingControlService
    var canControl = true
    var body: some View {
        Picker(L10n.text("팬 설정"), selection: Binding(get: { control.appliedMode }, set: { control.select($0) })) {
            ForEach(CoolingMode.allCases) { mode in
                Text(mode.title).tag(mode).disabled(mode != .system && (!canControl || control.registration != .enabled || control.needsRefresh))
            }
        }.disabled(control.busy)
    }
}

struct CoolingAccessView: View {
    @EnvironmentObject private var control: CoolingControlService
    @Environment(\.appearsActive) private var appearsActive
    var canControl = true
    private var showsRecovery: Bool {
        control.busy || control.registration != .enabled || control.needsRefresh || control.helperError != nil || control.message != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsRecovery {
                HelperRecoveryRow(message: recoveryMessage, working: control.busy,
                    needsApproval: control.registration == .requiresApproval,
                    disabled: setupDisabled, recover: { control.install() }, openSettings: { control.openSystemSettings() })
            }
            if !control.updatingHelper && control.registration != .requiresApproval {
                if let error = control.helperError {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let message = control.message {
                    Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !canControl {
                Text(L10n.text("센서 또는 팬 정보를 확인할 수 없어 제어를 사용할 수 없습니다."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.bottom, showsRecovery || !canControl ? 8 : 0)
        .onAppear { control.refresh() }
        .onChange(of: appearsActive) { _, active in if active { control.refresh() } }
    }
    private var setupDisabled: Bool { !canControl || control.busy || control.appliedMode != .system }
    private var recoveryMessage: String {
        if control.busy { return L10n.text("설정을 복구하고 연결을 확인하는 중입니다.") }
        if control.registration == .requiresApproval { return L10n.text("macOS에서 Lookout의 백그라운드 실행을 허용해주세요.") }
        if control.needsRefresh { return L10n.text("팬 제어 도우미가 변경되어 설정 복구가 필요합니다.") }
        return L10n.text("팬 제어 도우미의 등록·연결을 확인해주세요.")
    }

}

extension CoolingTemperatureBand {
    var tint: Color {
        switch self { case .normal: .primary; case .warm: .orange; case .hot: .red }
    }
}
