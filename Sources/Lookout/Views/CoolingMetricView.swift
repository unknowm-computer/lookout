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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if control.updatingHelper {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("팬 제어를 자동으로 갱신하는 중입니다."))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else if control.registration == .requiresApproval {
                HStack {
                    Text(L10n.text("macOS에서 Lookout의 백그라운드 실행을 다시 허용해주세요."))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 3)
                    Button(L10n.text("시스템 설정에서 허용")) { control.openSystemSettings() }
                }.font(.system(size: 11))
            } else if !control.helperPreviouslyEnabled {
                HStack {
                    Text(L10n.text("온도 기반 제어는 최초 활성화가 필요합니다.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 3)
                    Button(L10n.text("팬 제어 활성화")) { control.install() }.disabled(!canControl || control.busy)
                }.font(.system(size: 10))
            } else if let error = control.helperError {
                HStack {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 3)
                    Button(L10n.text("다시 시도")) { control.install() }.disabled(!canControl || control.busy)
                }.font(.system(size: 10))
            }
            if let message = control.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !canControl {
                Text(L10n.text("센서 또는 팬 정보를 확인할 수 없어 제어를 사용할 수 없습니다."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onAppear { control.prepareHelperAfterUpdate() }
        .onChange(of: appearsActive) { _, active in if active { control.prepareHelperAfterUpdate() } }
    }
}

extension CoolingTemperatureBand {
    var tint: Color {
        switch self { case .normal: .primary; case .warm: .orange; case .hot: .red }
    }
}
