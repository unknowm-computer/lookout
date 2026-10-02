import LookoutCore
import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var menuBar: MenuBarController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lookout 표시 방식").font(.system(size: 13, weight: .semibold))
                    HoverSegmentedPicker(title: "메뉴바 표시 방식", selection: Binding(
                        get: { settings.menuBarDisplayMode },
                        set: { settings.setMenuBarDisplayMode($0) }
                    ), options: MenuBarDisplayMode.allCases.map { SegmentOption(value: $0, title: $0.title) })
                    Text(settings.menuBarDisplayMode == .individual
                         ? "각 항목을 클릭하면 해당 상세가 열립니다. ⌘ 키를 누른 채 드래그하여 항목별 위치를 옮길 수 있습니다."
                         : "활성 항목을 하나로 묶고, 클릭하면 전체 상세를 표시합니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("메뉴바 표시 범위").font(.system(size: 13, weight: .semibold))
                    HoverSegmentedPicker(title: "메뉴바 표시 범위", selection: Binding(
                        get: { settings.menuBarDensity },
                        set: { settings.setMenuBarDensity($0) }
                    ), options: MenuBarDensity.allCases.map { SegmentOption(value: $0, title: $0.title) })
                    Text("자동: 공간에 맞춰 표시 · 일반: 전체 · 축소: 우선순위 상위 2개 · 최소: 상위 1개")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("현재 \(menuBar.displayedMetrics.count)개 · \(displayedTitles)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("menu-bar-density-summary")
                    Text("숨긴 항목도 계속 모니터링합니다. 전체 상세는 ⌘⇧M으로 열 수 있습니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.menuBarDensity == .automatic {
                        Text(menuBar.layoutMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("현재 사용 화면\(menuBar.layoutScreenName.map { " (\($0))" } ?? "")을 기준으로 조절합니다. 설정 창 사용 중에는 해당 화면을, 그 외에는 포인터가 있는 화면을 기준으로 합니다. 항목 구성은 모든 메뉴바에 공통 적용됩니다.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시 우선순위").font(.system(size: 13, weight: .semibold))
                    Text("공간이 부족하면 위쪽 항목부터 남깁니다. 배치 순서는 모니터링 탭에서 따로 정합니다.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MetricReorderList(scope: .priority, order: settings.menuBarPriority, spacing: 8,
                                      move: { settings.moveMenuBarPriority($0, to: $1) }) { metric, index in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
                            Text(metric.title)
                            if !settings.capabilities.supports(metric) {
                                Text("미지원").foregroundStyle(.tertiary)
                            } else if !settings.configuration.enabled.contains(metric) {
                                Text("꺼짐").foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }.font(.system(size: 12))
                    }
                    Text("오른쪽 손잡이를 드래그하여 우선순위를 바꿉니다. 평소 배치 순서는 유지됩니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SpacingSettingsView()
            }.padding(.trailing, 3)
        }
    }
    private var displayedTitles: String {
        let metrics = menuBar.displayedMetrics
        return metrics.isEmpty ? "모니터링 꺼짐" : metrics.map(\.title).joined(separator: " · ")
    }
}
