import AppKit
import LookoutCore
import SwiftUI

struct MonitorPanel: View {
    @ObservedObject var monitor: MonitoringCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notifications: NotificationService
    var onOpenSettings: (() -> Void)? = nil
    var onSizeChange: ((CGSize) -> Void)? = nil
    var presented = true
    var initialScreenHeight: CGFloat? = nil
    var selectedMetrics: [Metric]? = nil
    @State private var visible = false
    @State private var screenHeight = NSScreen.main?.visibleFrame.height ?? 720
    @State private var headerHeight: CGFloat = 36
    @State private var footerHeight: CGFloat = 36
    @State private var contentHeight: CGFloat?
    @State private var tooltipViewportSize: CGSize?
    @State private var isOpeningActivityMonitor = false
    @State private var activityMonitorError: String?
    private var metrics: [Metric] {
        settings.configuration.visible.filter { selectedMetrics?.contains($0) ?? true }
    }
    private var activeAlerts: [AlertEvent] {
        monitor.activeAlerts.filter { selectedMetrics?.contains($0.metric) ?? true }
    }
    private var scrollHeight: CGFloat {
        // The 80% limit includes the header and footer, not just the scrolling content.
        let maximum = max(1, screenHeight * 0.8 - headerHeight - footerHeight - 2)
        return min(contentHeight ?? maximum, maximum)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LOOKOUT").font(.system(size: 10, weight: .semibold)).tracking(1.6)
                Spacer()
                Text(metrics == [.ssd] ? "저장공간" : "최근 5분").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            Divider()
            if metrics.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("모니터링 항목을 선택하세요").font(.system(size: 12))
                    Text("설정에서 필요한 항목만 켤 수 있습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("panel-top")
                            if !activeAlerts.isEmpty {
                                ActiveAlertsView(alerts: activeAlerts, readings: monitor.readings)
                                Divider()
                            }
                            ForEach(metrics) { metric in
                                MetricSection(metric: metric, reading: monitor.readings[metric],
                                              history: monitor.histories[metric] ?? HistoryBuffer(),
                                              end: monitor.lastUpdate, visible: visible,
                                              chartStyle: settings.charts.style(for: metric), showsSwapDetails: settings.showsSwapDetails,
                                              processDetails: monitor.processDetails,
                                              processesInitiallyExpanded: settings.menuBarDisplayMode == .individual)
                                if metric != metrics.last { Divider().padding(.horizontal, 16) }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }.frame(height: scrollHeight)
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .scrollDisabled(contentHeight.map { $0 <= scrollHeight } ?? false)
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear {
                        proxy.scrollTo("panel-top", anchor: .top)
                    }
                    .onChange(of: notifications.panelRequest) { _, _ in proxy.scrollTo("panel-top", anchor: .top) }
                }
                // Rebuild the viewport when items are removed/reordered so an old offset cannot
                // survive into a shorter, non-scrollable panel. Metric sampling stays independent.
                .id(metrics)
                .coordinateSpace(name: UsageTooltipSpace.viewport)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipViewportSize = $0 }
                .environment(\.usageTooltipViewportSize, tooltipViewportSize)
            }
            Divider()
            HStack {
                Button {
                    onOpenSettings?()
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("설정…", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
                Button {
                    isOpeningActivityMonitor = true
                    Task {
                        defer { isOpeningActivityMonitor = false }
                        do { try await ActivityMonitorLauncher.open() }
                        catch { activityMonitorError = error.localizedDescription }
                    }
                } label: { Label("활성 상태 보기", systemImage: "waveform.path.ecg") }
                .disabled(isOpeningActivityMonitor)
                .help("macOS 활성 상태 보기 열기")
                Spacer()
                Button("종료") { monitor.stop(); NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(PanelActionButtonStyle(borderless: true)).font(.system(size: 11))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: 340)
        // Report the intrinsic content height to either the preview window or the native popover.
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .alert("활성 상태 보기를 열 수 없습니다.", isPresented: Binding(
            get: { activityMonitorError != nil },
            set: { if !$0 { activityMonitorError = nil } }
        )) {
            Button("확인", role: .cancel) { activityMonitorError = nil }
        } message: { Text(activityMonitorError ?? "") }
        .background(PanelScreenReader { screenHeight = $0 })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange?($0) }
        .onAppear {
            if let initialScreenHeight { screenHeight = initialScreenHeight }
            visible = presented
        }
        .onChange(of: presented) { _, value in visible = value }
        .onDisappear { visible = false }
    }
}

private struct MetricSection: View {
    let metric: Metric
    let reading: MetricReading?
    let history: HistoryBuffer
    let end: Date
    let visible: Bool
    let chartStyle: ChartStyle
    let showsSwapDetails: Bool
    let processDetails: ProcessDetailsStore
    let processesInitiallyExpanded: Bool
    private var color: Color {
        switch metric {
        case .cpu: .cyan; case .memory: .purple; case .network: .green
        case .disk, .ssd: .blue; case .power: .yellow; case .gpu: .orange
        }
    }
    private var summary: String {
        guard let value = reading?.value else { return "—" }
        switch value {
        case .cpu(let value): return ValueFormat.percent(value)
        case .memory(let value): return "\(ValueFormat.memory(value.used)) / \(ValueFormat.memory(value.total))"
        case .network(let value): return value.interface
        case .disk: return ""
        case .storage(let capacity): return "\(ValueFormat.storage(capacity.used)) / \(ValueFormat.storage(capacity.total))"
        case .power(let value): return value.watts.map(ValueFormat.watts) ?? "—"
        case .gpu(let value): return ValueFormat.percent(value.utilization)
        }
    }
    private var storage: DiskCapacityReading? {
        if case .storage(let capacity) = reading?.value { return capacity }; return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if metric == .ssd {
                StorageMetricSummary(capacity: storage, message: reading?.message)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: metric.symbol).foregroundStyle(color).frame(width: 16)
                    Text(metric.title).fontWeight(.semibold)
                    Spacer()
                    if metric == .network {
                        Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if metric != .disk {
                        Text(summary).monospacedDigit().fontWeight(.medium)
                    }
                }.font(.system(size: 12))
                if visible {
                    MetricVisualization(metric: metric, reading: reading, history: history.points,
                                        end: end, preference: chartStyle, color: color, showsSwapDetails: showsSwapDetails)
                }
                details
                ProcessListDisclosure(metric: metric, reading: reading, visible: visible, details: processDetails,
                                      initiallyExpanded: processesInitiallyExpanded)
            }
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }
    @ViewBuilder private var details: some View {
        if let value = reading?.value {
            switch value {
            case .cpu:
                EmptyView()
            case .memory:
                EmptyView()
            case .network(let value):
                HStack(spacing: 14) {
                    networkRate("다운로드", value.download, .green)
                    networkRate("업로드", value.upload, .orange)
                }
            case .disk, .storage:
                EmptyView()
            case .power:
                EmptyView()
            case .gpu(let value):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(value.name).lineLimit(1)
                        Spacer()
                        if let memory = value.sharedMemory { Text("공유 \(ValueFormat.memory(memory))").monospacedDigit() }
                    }
                    HStack {
                        Text("렌더링 \(value.renderer.map(ValueFormat.percent) ?? "—")")
                        Spacer()
                        Text("타일링 \(value.tiler.map(ValueFormat.percent) ?? "—")")
                    }.monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else {
            Text(reading?.message ?? "측정을 시작하는 중")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func networkRate(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(ValueFormat.rate(value)).monospacedDigit().fontWeight(.medium)
        }.font(.system(size: 11)).frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("네트워크 \(label) 속도")
            .accessibilityValue(ValueFormat.rate(value))
    }
}
