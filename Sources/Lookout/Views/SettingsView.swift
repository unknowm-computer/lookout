import LookoutCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: MonitoringCoordinator
    @ObservedObject var updates: UpdateService
    @ObservedObject var menuBar: MenuBarController
    @State private var tab = 0
    @State private var showingUpdates = false
    @State private var showingLanguageRestart = false
    @State private var restarting = false
    @State private var restartError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 27)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lookout").font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("필요한 정보만, 메뉴바에서.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HoverSegmentedPicker(title: L10n.text("설정 영역"), selection: $tab, options: [
                SegmentOption(value: 0, title: L10n.text("모니터링")),
                SegmentOption(value: 2, title: L10n.text("알림")),
                SegmentOption(value: 1, title: L10n.text("메뉴바"))
            ])
            if tab == 0 {
                ScrollView { monitoring.padding(.trailing, 3) }
            } else if tab == 1 { MenuBarSettingsView(settings: settings, menuBar: menuBar) }
            else { AlertSettingsView(settings: settings, notifications: monitor.notifications) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text(L10n.text("Lookout \(updates.version) · macOS Sequoia 15 이상"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.text("업데이트…")) { showingUpdates = true }
                    .font(.system(size: 11))
                    .popover(isPresented: $showingUpdates) { UpdateSettingsView(updates: updates) }
            }
        }
        .padding(24).frame(width: 480, height: 560)
        .buttonStyle(PanelActionButtonStyle())
        .onAppear { monitor.refreshInterfaces() }
        .alert(L10n.text("언어 변경 적용"), isPresented: $showingLanguageRestart) {
            Button(L10n.text("나중에"), role: .cancel) {}
            Button(L10n.text("지금 재시작")) { restartForLanguage() }
        } message: {
            Text(L10n.text("선택한 언어를 적용하려면 Lookout을 다시 시작해야 합니다. 지금 재시작할까요?"))
        }
        .alert(L10n.text("재시작할 수 없습니다."), isPresented: Binding(
            get: { restartError != nil }, set: { if !$0 { restartError = nil } }
        )) {
            Button(L10n.text("확인")) { restartError = nil }
        } message: { Text(restartError ?? "") }
    }
    private func restartForLanguage() {
        guard !restarting else { return }
        restarting = true
        Task { @MainActor in
            do { try await AppRelauncher().restart() }
            catch { restartError = error.localizedDescription; restarting = false }
        }
    }
    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("언어"))
                Spacer()
                Picker(L10n.text("언어"), selection: Binding(
                    get: { settings.language },
                    set: { language in
                        guard language != settings.language else { return }
                        settings.setLanguage(language)
                        showingLanguageRestart = true
                    }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 180).disabled(restarting)
            }
            Text(L10n.text("언어 변경은 앱을 다시 실행하면 적용됩니다."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var monitoring: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoginItemSettingsView()
            languageSettings
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L10n.text("모니터링 항목 · 왼쪽부터 표시 순서"))
                MetricReorderList(scope: .placement, order: settings.configuration.order, separators: true,
                                  footnote: { metric in
                                      settings.capabilities.unsupportedReason(for: metric)
                                          ?? (metric == .disk ? L10n.text("macOS가 실행 중인 디스크의 읽기·쓰기 속도를 측정합니다.") : nil)
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
                            Toggle(L10n.text("Swap 상세"), isOn: Binding(
                                get: { settings.showsSwapDetails },
                                set: { settings.setShowsSwapDetails($0) }
                            )).toggleStyle(.checkbox)
                                .font(.system(size: 10))
                                .fixedSize(horizontal: true, vertical: false)
                                .disabled(!settings.configuration.enabled.contains(.memory))
                                .help(L10n.text("체크하면 Swap 바 그래프와 사용·할당 여유를 표시합니다. 해제하면 사용량/현재 할당량 한 줄만 표시합니다."))
                        }
                        Spacer(minLength: 8)
                        if metric == .ssd {
                            Text(L10n.text("체크 주기")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            Picker(L10n.text("SSD 체크 주기"), selection: Binding(
                                get: { settings.configuration.storageInterval },
                                set: { settings.setStorageInterval($0) }
                            )) {
                                ForEach(StoragePollingInterval.allCases) { Text($0.title).tag($0.rawValue) }
                            }.labelsHidden().frame(width: 110)
                                .disabled(!settings.configuration.enabled.contains(.ssd))
                        } else {
                            Text(L10n.text("그래프")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            Picker(L10n.text("\(metric.title) 그래프 형식"), selection: Binding(
                                get: { settings.charts.style(for: metric) },
                                set: { settings.setChartStyle($0, for: metric) }
                            )) {
                                ForEach(ChartStyle.available(for: metric)) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 110)
                                .disabled(!settings.configuration.enabled.contains(metric))
                        }
                    }.padding(4)
                }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.text("오른쪽 손잡이를 드래그하여 배치 순서를 바꿉니다. 끄면 표시와 데이터 수집이 함께 중단됩니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.text("갱신 주기"))
                    Spacer()
                    Picker(L10n.text("갱신 주기"), selection: Binding(get: { settings.configuration.interval }, set: { settings.setInterval($0) })) {
                        Text(L10n.text("1초")).tag(1); Text(L10n.text("2초")).tag(2); Text(L10n.text("3초")).tag(3); Text(L10n.text("5초")).tag(5)
                    }.labelsHidden().frame(width: 160)
                }
                Text(L10n.text("SSD 저장공간은 위 SSD 항목의 설정을 따릅니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.text("네트워크 인터페이스"))
                    Spacer()
                    Button { monitor.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L10n.text("네트워크 인터페이스 새로고침"))
                }
                Picker(L10n.text("네트워크 인터페이스"), selection: Binding(
                    get: { settings.configuration.interface ?? "auto" },
                    set: { settings.setInterface($0 == "auto" ? nil : $0) }
                )) {
                    Text(L10n.text("자동 · 기본 연결")).tag("auto")
                    ForEach(availableInterfaces, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
                Text(L10n.text("한 인터페이스만 측정합니다. VPN 트래픽을 확인하려면 해당 인터페이스를 선택하세요."))
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
