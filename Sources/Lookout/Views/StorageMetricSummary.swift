import AppKit
import LookoutCore
import SwiftUI

/// Independent SSD metric with a fixed capacity bar and a storage-management shortcut.
struct StorageMetricSummary: View {
    let capacity: DiskCapacityReading?
    let message: String?
    @State private var showingSettingsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "internaldrive").foregroundStyle(.blue).frame(width: 16)
                Text(L10n.text("SSD 저장공간")).fontWeight(.semibold)
                Spacer()
                HStack(spacing: 3) {
                    Text(capacity.map { "\(ValueFormat.storage($0.used)) / \(ValueFormat.storage($0.total))" } ?? "—")
                        .monospacedDigit().fontWeight(.medium)
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                            showingSettingsError = !NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                    }
                    .buttonStyle(PanelActionButtonStyle(borderless: true, horizontalPadding: 3))
                    .accessibilityLabel(L10n.text("저장 공간 관리 열기"))
                    .help(L10n.text("시스템 설정에서 저장 공간 관리 열기"))
                }
            }.font(.system(size: 12))
            if let capacity {
                SegmentedUsageBar(segments: storageSegments(capacity), accessibilityTitle: L10n.text("SSD 저장공간 현재 상태 막대"))
                HStack(spacing: 16) {
                    amount(L10n.text("사용"), capacity.used, color: .blue)
                    amount(L10n.text("남은 용량"), capacity.available, color: .secondary.opacity(0.4))
                }.font(.system(size: 10))
            } else {
                Text(message ?? L10n.text("SSD 용량을 측정하는 중"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(L10n.text("저장 공간 설정을 열 수 없습니다."), isPresented: $showingSettingsError) {
            Button(L10n.text("확인"), role: .cancel) {}
        } message: {
            Text(L10n.text("시스템 설정의 일반 → 저장 공간에서 직접 열 수 있습니다."))
        }
    }
    private func storageSegments(_ capacity: DiskCapacityReading) -> [UsageBarSegment] {
        guard capacity.total.isFinite, capacity.total > 0 else { return [] }
        let used = capacity.percent / 100
        return [UsageBarSegment(id: "used", title: L10n.text("SSD 사용"), fraction: used, color: .blue,
                                summary: L10n.text("SSD 사용 · \(ValueFormat.storage(capacity.used)) · \(ValueFormat.percent(capacity.percent))")),
                UsageBarSegment(id: "free", title: L10n.text("SSD 남은 용량"), fraction: 1 - used, color: .secondary.opacity(0.4),
                                summary: L10n.text("SSD 남은 용량 · \(ValueFormat.storage(capacity.available)) · \(ValueFormat.percent(100 - capacity.percent))"))]
    }
    private func amount(_ title: String, _ bytes: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(ValueFormat.storage(bytes)).monospacedDigit()
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
    }
}
