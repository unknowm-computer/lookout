import LookoutCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: MonitoringCoordinator
    @ObservedObject var updates: UpdateService
    @ObservedObject var menuBar: MenuBarController
    @State private var tab = 0
    @State private var showingUpdates = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 27)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lookout").font(.system(size: 20, weight: .semibold))
                    Text("필요한 정보만, 메뉴바에서.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HoverSegmentedPicker(title: "설정 영역", selection: $tab, options: [
                SegmentOption(value: 0, title: "모니터링"),
                SegmentOption(value: 2, title: "알림"),
                SegmentOption(value: 1, title: "메뉴바")
            ])
            if tab == 0 {
                ScrollView { monitoring.padding(.trailing, 3) }
            } else if tab == 1 { MenuBarSettingsView(settings: settings, menuBar: menuBar) }
            else { AlertSettingsView(settings: settings, notifications: monitor.notifications) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("Lookout \(updates.version) · macOS Sequoia 15 이상")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("업데이트…") { showingUpdates = true }
                    .font(.system(size: 11))
                    .popover(isPresented: $showingUpdates) { UpdateSettingsView(updates: updates) }
            }
        }
        .padding(24).frame(width: 480, height: 560)
        .buttonStyle(PanelActionButtonStyle())
        .onAppear { monitor.refreshInterfaces() }
    }
    private var monitoring: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoginItemSettingsView()
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("모니터링 항목 · 왼쪽부터 표시 순서")
                MetricReorderList(scope: .placement, order: settings.configuration.order, separators: true,
                                  footnote: { metric in
                                      settings.capabilities.unsupportedReason(for: metric)
                                          ?? (metric == .disk ? "macOS가 실행 중인 디스크의 읽기·쓰기 속도를 측정합니다." : nil)
                                  },
                                  move: { settings.move($0, to: $1) }) { metric, _ in
                    HStack(spacing: 8) {
                        Image(systemName: metric.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Toggle(metric.title, isOn: Binding(
                            get: { settings.configuration.enabled.contains(metric) },
                            set: { settings.setEnabled(metric, $0) }
                        )).toggleStyle(.checkbox)
                            .disabled(!settings.capabilities.supports(metric))
                            .fixedSize(horizontal: true, vertical: false)
                        if metric == .memory {
                            Toggle("Swap 상세", isOn: Binding(
                                get: { settings.showsSwapDetails },
                                set: { settings.setShowsSwapDetails($0) }
                            )).toggleStyle(.checkbox)
                                .font(.system(size: 10))
                                .fixedSize(horizontal: true, vertical: false)
                                .disabled(!settings.configuration.enabled.contains(.memory))
                                .help("체크하면 Swap 바 그래프와 사용·할당 여유를 표시합니다. 해제하면 사용량/현재 할당량 한 줄만 표시합니다.")
                        }
                        Spacer(minLength: 8)
                        if metric == .ssd {
                            Text("체크 주기").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            Picker("SSD 체크 주기", selection: Binding(
                                get: { settings.configuration.storageInterval },
                                set: { settings.setStorageInterval($0) }
                            )) {
                                ForEach(StoragePollingInterval.allCases) { Text($0.title).tag($0.rawValue) }
                            }.labelsHidden().frame(width: 110)
                                .disabled(!settings.configuration.enabled.contains(.ssd))
                        } else {
                            Text("그래프").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            Picker("\(metric.title) 그래프 형식", selection: Binding(
                                get: { settings.charts.style(for: metric) },
                                set: { settings.setChartStyle($0, for: metric) }
                            )) {
                                ForEach(ChartStyle.available(for: metric)) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 110)
                                .disabled(!settings.configuration.enabled.contains(metric))
                        }
                    }.padding(4)
                }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                Text("오른쪽 손잡이를 드래그하여 배치 순서를 바꿉니다. 끄면 표시와 데이터 수집이 함께 중단됩니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("갱신 주기")
                    Spacer()
                    Picker("갱신 주기", selection: Binding(get: { settings.configuration.interval }, set: { settings.setInterval($0) })) {
                        Text("1초").tag(1); Text("2초").tag(2); Text("3초").tag(3); Text("5초").tag(5)
                    }.labelsHidden().frame(width: 160)
                }
                Text("SSD 저장공간은 위 SSD 항목의 설정을 따릅니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("네트워크 인터페이스")
                    Spacer()
                    Button { monitor.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("네트워크 인터페이스 새로고침")
                }
                Picker("네트워크 인터페이스", selection: Binding(
                    get: { settings.configuration.interface ?? "auto" },
                    set: { settings.setInterface($0 == "auto" ? nil : $0) }
                )) {
                    Text("자동 · 기본 연결").tag("auto")
                    ForEach(availableInterfaces, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
                Text("한 인터페이스만 측정합니다. VPN 트래픽을 확인하려면 해당 인터페이스를 선택하세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12))
    }
    private var availableInterfaces: [String] {
        var names = monitor.interfaces
        if let selected = settings.configuration.interface, !names.contains(selected) { names.append(selected) }
        return names.sorted()
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}
