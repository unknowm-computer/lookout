import LookoutCore
import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var menuBar: MenuBarController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Lookout 표시 방식")).font(.system(size: 13, weight: .semibold))
                    HoverSegmentedPicker(title: L10n.text("메뉴바 표시 방식"), selection: Binding(
                        get: { settings.menuBarDisplayMode },
                        set: { settings.setMenuBarDisplayMode($0) }
                    ), options: MenuBarDisplayMode.allCases.map { SegmentOption(value: $0, title: $0.title) })
                    Text(settings.menuBarDisplayMode == .individual
                         ? L10n.text("각 항목을 클릭하면 해당 상세가 열립니다. ⌘ 드래그로 위치를 옮길 수 있으며, 재실행·항목 구성 변경 시 모니터링 탭 순서를 적용합니다.")
                         : L10n.text("활성 항목을 하나로 묶고, 클릭하면 전체 상세를 표시합니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                MenuBarGroupingEditor(grouping: settings.configuration.menuBarGrouping,
                    order: settings.configuration.order, enabled: settings.configuration.enabled,
                    supported: Set(MenuBarGrouping.eligible.filter(settings.capabilities.supports)),
                    change: { settings.setMenuBarGrouping($0) })
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("RAM / SSD 표시 값")).font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([Metric.memory, .ssd]) { metric in
                            HStack(spacing: 8) {
                                Text(metric == .memory ? "RAM" : "SSD").frame(width: 36, alignment: .leading)
                                Picker(L10n.text("표시 값"), selection: Binding(
                                    get: { settings.menuBarValues.mode(for: metric).capacity },
                                    set: { settings.setMenuBarCapacity($0, for: metric) }
                                )) {
                                    ForEach([CapacityMenuBarValue.used, .available]) { value in
                                        Text(value.title).tag(value)
                                    }
                                }.labelsHidden().frame(width: 140)
                                    .accessibilityLabel(L10n.text("\(metric == .memory ? "RAM" : "SSD") 메뉴바 표시 값"))
                                Toggle(L10n.text("%로 표시"), isOn: Binding(
                                    get: { settings.menuBarValues.mode(for: metric).isPercentage },
                                    set: { settings.setMenuBarPercentage($0, for: metric) }
                                )).toggleStyle(.checkbox)
                                    .accessibilityLabel(L10n.text("\(metric == .memory ? "RAM" : "SSD") %로 표시"))
                            }
                        }
                    }.font(.system(size: 12))
                    Text(L10n.text("RAM 옆 점은 메모리 압력입니다: 녹색 정상 · 노란색 주의 · 빨간색 부족 · 회색 확인 불가. SSD 기본값은 남은 용량입니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("SSD 끝의 청록색 점은 남은 용량·비율을 뜻합니다. 사용 용량·사용률에는 점을 표시하지 않습니다. 알림이 활성화되면 해당 수치가 빨간색으로 표시됩니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("RAM 남은 용량은 전체−현재 사용량이며, 앞으로 압축·회수할 수 있는 모든 공간을 뜻하지는 않습니다."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("메뉴바 표시 범위")).font(.system(size: 13, weight: .semibold))
                    HoverSegmentedPicker(title: L10n.text("메뉴바 표시 범위"), selection: Binding(
                        get: { settings.menuBarDensity },
                        set: { settings.setMenuBarDensity($0) }
                    ), options: MenuBarDensity.allCases.map { SegmentOption(value: $0, title: $0.title) })
                    Text(L10n.text("자동: 공간에 맞춰 표시 · 일반: 전체 · 축소: 상위 2개 · 최소: 상위 1개. 묶인 두 항목은 1개로 계산합니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("현재 \(menuBar.displayedUnits.count)개 · \(displayedTitles)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("menu-bar-density-summary")
                    Text(L10n.text("숨긴 항목도 계속 모니터링합니다. 전체 상세는 ⌘⇧M으로 열 수 있습니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.menuBarDensity == .automatic {
                        Text(menuBar.layoutMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("현재 사용 화면\(menuBar.layoutScreenName.map { " (\($0))" } ?? "")을 기준으로 조절합니다. 설정 창 사용 중에는 해당 화면을, 그 외에는 포인터가 있는 화면을 기준으로 합니다. 항목 구성은 모든 메뉴바에 공통 적용됩니다."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("표시 우선순위")).font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("공간이 부족하면 위쪽 항목부터 남깁니다. 배치 순서는 모니터링 탭에서 따로 정합니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("그룹은 위쪽 항목의 모니터링 위치를 사용하며, 공간 부족 시 두 항목 중 높은 표시 우선순위를 따릅니다."))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    MetricReorderList(scope: .priority, order: settings.menuBarPriority, spacing: 8,
                                      move: { settings.moveMenuBarPriority($0, to: $1) }) { metric, index in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
                            Text(metric.title)
                            if !settings.capabilities.supports(metric) {
                                Text(L10n.text("미지원")).foregroundStyle(.tertiary)
                            } else if !settings.configuration.enabled.contains(metric) {
                                Text(L10n.text("꺼짐")).foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }.font(.system(size: 12))
                    }
                    Text(L10n.text("오른쪽 손잡이를 드래그하여 우선순위를 바꿉니다. 평소 배치 순서는 유지됩니다."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SpacingSettingsView()
            }.padding(.trailing, 3)
        }
    }
    private var displayedTitles: String {
        let units = menuBar.displayedUnits
        return units.isEmpty ? L10n.text("모니터링 꺼짐") : units.map(\.title).joined(separator: " · ")
    }
}
