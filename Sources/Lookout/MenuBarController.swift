import AppKit
import Combine
import LookoutCore
import SwiftUI

/// Own the status buttons and popup size together. SwiftUI supplies content, not a second window-size policy.
@MainActor final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var presented = false
    @Published private(set) var displayedMetrics: [Metric] = []
    @Published private(set) var layoutMessage = "메뉴바 위치를 확인하는 중입니다."
    @Published private(set) var layoutScreenName: String?
    private let settings: SettingsStore
    private let monitor: MonitoringCoordinator
    private let updates: UpdateService
    private enum Slot: Hashable {
        case combined
        case metric(Metric)
        var metric: Metric? {
            if case .metric(let metric) = self { return metric }
            return nil
        }
        var autosaveName: String { "Lookout.priority.left-to-right.\(metric?.rawValue ?? "combined")" }
    }
    private var statusItems: [Slot: NSStatusItem] = [:]
    private var started = false
    private var displayMode: MenuBarDisplayMode?
    private var placementOrder: [Metric] = []
    private var automaticLimit: Int?
    private var expansionGate = MenuBarExpansionGate()
    private let widthEstimator = MenuBarWidthEstimator()
    private var layoutTask: Task<Void, Never>?
    private struct LayoutConfiguration: Equatable {
        let order: [Metric]
        let enabled: Set<Metric>
        let priority: [Metric]
        let mode: MenuBarDisplayMode
        let density: MenuBarDensity
    }
    private var layoutConfiguration: LayoutConfiguration?
    private var anchorSlot: Slot?
    private var selectedMetric: Metric?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var presentationID = UUID()
    private var buttonUpdateQueued = false

    init(settings: SettingsStore, monitor: MonitoringCoordinator, updates: UpdateService) {
        self.settings = settings; self.monitor = monitor; self.updates = updates
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }
    func start() {
        guard !started else { return }
        started = true
        Publishers.MergeMany(settings.objectWillChange.map { _ in () }, monitor.objectWillChange.map { _ in () })
            .sink { [weak self] in
                self?.scheduleButtonUpdate()
            }.store(in: &subscriptions)
        monitor.notifications.$panelRequest.compactMap { $0 }.sink { [weak self] _ in
            self?.showPanel()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.automaticLimit = nil
                self?.expansionGate = MenuBarExpansionGate()
                self?.scheduleButtonUpdate()
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.scheduleLayoutCheck() }
            .store(in: &subscriptions)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.scheduleLayoutCheck() }
            .store(in: &subscriptions)
        updateButton()
    }
    private func scheduleButtonUpdate() {
        guard !buttonUpdateQueued else { return }
        buttonUpdateQueued = true
        // ObservableObject publishes before mutation. Coalesce all metrics from one sampling pass.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.buttonUpdateQueued = false
            self.updateButton()
        }
    }
    private func updateButton() {
        let nextLayout = LayoutConfiguration(order: settings.configuration.order,
            enabled: settings.configuration.enabled, priority: settings.menuBarPriority,
            mode: settings.menuBarDisplayMode, density: settings.menuBarDensity)
        if layoutConfiguration != nextLayout {
            automaticLimit = nil
            expansionGate = MenuBarExpansionGate()
            layoutConfiguration = nextLayout
            if settings.menuBarDensity == .automatic { layoutMessage = "메뉴바 위치를 확인하는 중입니다." }
        }
        let visible = settings.menuBarDensity.metrics(configuration: settings.configuration,
            priority: settings.menuBarPriority, automaticLimit: automaticLimit)
        let slots: [Slot] = settings.menuBarDisplayMode == .combined || visible.isEmpty
            ? [.combined] : visible.map(Slot.metric)
        let orderChanged = placementOrder != settings.configuration.order
        let selectionChanged = displayedMetrics != visible
        if orderChanged || selectionChanged || displayMode != settings.menuBarDisplayMode || anchorSlot.map({ !slots.contains($0) }) == true {
            if popover.isShown { popover.performClose(nil) }
        }
        displayMode = settings.menuBarDisplayMode
        if orderChanged || selectionChanged {
            for item in statusItems.values { NSStatusBar.system.removeStatusItem(item) }
            statusItems.removeAll()
            placementOrder = settings.configuration.order
        }
        if displayedMetrics != visible { displayedMetrics = visible }
        if visible.isEmpty { layoutMessage = "모니터링할 항목을 선택하세요." }
        for slot in Array(statusItems.keys) where !slots.contains(slot) {
            if let item = statusItems.removeValue(forKey: slot) { NSStatusBar.system.removeStatusItem(item) }
        }
        // New items enter from the left: create in reverse to preserve the settings order left to right.
        // A new priority order has its own saved placement, so old manual positions cannot
        // override a newly chosen order. Sampling retains all existing items.
        let orderName = placementOrder.map(\.rawValue).joined(separator: "-") + "." + visible.map(\.rawValue).joined(separator: "-")
        for slot in slots.reversed() where statusItems[slot] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "\(slot.autosaveName).\(orderName)"
            item.button?.target = self
            item.button?.action = #selector(togglePanel(_:))
            item.button?.setAccessibilityIdentifier("lookout-status-\(slot.metric?.rawValue ?? "combined")")
            statusItems[slot] = item
        }
        for slot in slots {
            guard let button = statusItems[slot]?.button else { continue }
            let metrics = slot.metric.map { [$0] } ?? visible
            let monitored = slot.metric == nil ? settings.configuration.enabled : Set(metrics)
            let hasAlert = monitor.activeAlerts.contains { monitored.contains($0.metric) }
            button.image = metrics.isEmpty ? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Lookout · 모니터링 꺼짐") :
                MenuBarRenderer.image(metrics: metrics, readings: monitor.readings,
                    showAlertSlot: settings.alerts.hasEnabledRules(monitored: monitored),
                    hasAlert: hasAlert, compact: slot.metric != nil)
            button.toolTip = slot.metric.map { "Lookout · \($0.title)" } ?? "Lookout · 전체 모니터링"
            button.setAccessibilityLabel(slot.metric.map { "Lookout \($0.title)" } ?? "Lookout 모니터링")
            button.setAccessibilityValue(accessibilityValue(metrics: metrics) + (hasAlert ? " · 경고" : ""))
        }
        scheduleLayoutCheck()
    }
    private func scheduleLayoutCheck() {
        guard settings.menuBarDensity == .automatic else { layoutTask?.cancel(); return }
        layoutTask?.cancel()
        layoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.evaluateLayout()
        }
    }
    private func evaluateLayout() {
        guard settings.menuBarDensity == .automatic, !popover.isShown else { return }
        let ranked = settings.menuBarPriority.filter { settings.configuration.enabled.contains($0) }
        guard !ranked.isEmpty else { return }
        let preferredScreen = NSApp.isActive && settingsWindow?.isKeyWindow == true ? settingsWindow?.screen : nil
        guard let measurement = MenuBarGeometry.measure(statusItems.values.compactMap(\.button),
                                                        preferredScreen: preferredScreen) else {
            if layoutMessage != "현재 메뉴바 위치를 확인하지 못했습니다. 필요하면 축소·최소를 선택하세요." {
                layoutMessage = "현재 메뉴바 위치를 확인하지 못했습니다. 필요하면 축소·최소를 선택하세요."
            }
            return
        }
        let widths = widthEstimator.widths(settings: settings, measurement: measurement)
        guard let target = MenuBarSpacePolicy.limit(widths: widths, available: measurement.available) else { return }
        if layoutScreenName != measurement.screenName { layoutScreenName = measurement.screenName }
        let limit = expansionGate.resolve(target: target, current: displayedMetrics.count,
                                          uptime: ProcessInfo.processInfo.systemUptime)
        let message = measurement.available < (widths.first ?? 0)
            ? "공간이 매우 좁아 최우선 항목만 유지합니다. 메뉴바의 다른 항목을 옮기면 공간을 확보할 수 있습니다."
            : (target > limit ? "공간이 확보되어 숨긴 항목을 복원하는 중입니다."
               : (limit < ranked.count ? "공간이 부족해 낮은 우선순위 항목을 숨겼습니다. 공간이 확보되면 다시 표시합니다."
                                       : "공간이 충분해 전체 항목을 표시합니다."))
        if layoutMessage != message { layoutMessage = message }
        if ProcessInfo.processInfo.environment["LOOKOUT_LAYOUT_DIAGNOSTICS"] == "1" {
            let line = "Layout screen=\(measurement.screenName) budget=\(measurement.available) widths=\(widths) frames=\(measurement.frames) shown=\(displayedMetrics.map(\.rawValue)) target=\(target) next=\(limit)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        if automaticLimit != limit {
            automaticLimit = limit
            updateButton()
        }
    }
    private func accessibilityValue(metrics: [Metric]) -> String {
        metrics.map { metric in
            let value = monitor.readings[metric]?.value
            let text: String
            switch value {
            case .network(let network): text = "다운로드 \(ValueFormat.rate(network.download)), 업로드 \(ValueFormat.rate(network.upload))"
            case .disk(let disk): text = "읽기 \(disk.activity.map { ValueFormat.rate($0.read) } ?? "—"), 쓰기 \(disk.activity.map { ValueFormat.rate($0.write) } ?? "—")"
            case .power(let energy): text = energy.watts.map(ValueFormat.watts) ?? "—"
            default: text = value?.primary.map(ValueFormat.percent) ?? "—"
            }
            return "\(metric.title) \(text)"
        }.joined(separator: ", ")
    }
    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        guard let slot = statusItems.first(where: { $0.value.button === sender })?.key else { return }
        if popover.isShown, anchorSlot == slot, selectedMetric == slot.metric {
            popover.performClose(nil)
        } else {
            showPanel(anchoredTo: slot, metric: slot.metric)
        }
    }
    func showPanel() {
        // Menu command / notification opens the complete panel, even in individual mode.
        let candidates: [Slot] = [.combined] + settings.configuration.visible.map(Slot.metric)
        guard let slot = candidates.first(where: { statusItems[$0]?.button?.window?.screen != nil }) else { return }
        showPanel(anchoredTo: slot, metric: nil)
    }
    private func showPanel(anchoredTo slot: Slot, metric: Metric?) {
        guard let button = statusItems[slot]?.button else { return }
        if popover.isShown {
            if anchorSlot == slot, selectedMetric == metric { popover.contentViewController?.view.window?.makeKey(); return }
            popover.performClose(nil)
        }
        anchorSlot = slot
        selectedMetric = metric
        presented = true
        presentationID = UUID()
        let token = presentationID
        let screenHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 720
        let host = NSHostingController(rootView: StatusPopoverContent(owner: self, monitor: monitor, settings: settings,
            screenHeight: screenHeight, selectedMetric: metric, resize: { [weak self] size in
                Task { @MainActor [weak self] in self?.resize(size, token: token) }
            }))
        // Sizing belongs to the popover; avoid implicit hosting-window resizing from SwiftUI.
        host.sizingOptions = []
        popover.contentViewController = host
        let size = host.view.fittingSize
        popover.contentSize = NSSize(width: 340, height: min(max(1, size.height), screenHeight * 0.8))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func resize(_ size: CGSize, token: UUID) {
        guard token == presentationID, presented, size.height.isFinite, size.height > 0 else { return }
        let target = NSSize(width: 340, height: ceil(size.height))
        if popover.contentSize != target { popover.contentSize = target }
    }
    func popoverDidClose(_ notification: Notification) {
        presented = false
        anchorSlot = nil
        selectedMetric = nil
        // Invalidate queued geometry and discard view-local scroll/disclosure state on close.
        presentationID = UUID()
        popover.contentViewController = nil
        scheduleLayoutCheck()
    }
    func showSettings() {
        if popover.isShown { popover.performClose(nil) }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, monitor: monitor, updates: updates, menuBar: self))
            let window = NSWindow(contentViewController: host)
            window.title = "Lookout 설정"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 560))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StatusPopoverContent: View {
    @ObservedObject var owner: MenuBarController
    @ObservedObject var monitor: MonitoringCoordinator
    @ObservedObject var settings: SettingsStore
    let screenHeight: CGFloat
    let selectedMetric: Metric?
    let resize: (CGSize) -> Void
    var body: some View {
        MonitorPanel(monitor: monitor, settings: settings, notifications: monitor.notifications,
                     onOpenSettings: { owner.showSettings() }, onSizeChange: resize,
                     presented: owner.presented, initialScreenHeight: screenHeight, selectedMetric: selectedMetric)
    }
}
