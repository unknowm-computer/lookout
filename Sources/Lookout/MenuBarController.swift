import AppKit
import Combine
import LookoutCore
import SwiftUI

/// Own the status buttons and popup size together. SwiftUI supplies content, not a second window-size policy.
@MainActor final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var presented = false
    @Published private(set) var displayedMetrics: [Metric] = []
    var displayedUnits: [MenuBarUnit] { settings.configuration.menuBarGrouping.units(metrics: displayedMetrics) }
    @Published private(set) var layoutMessage = "메뉴바 위치를 확인하는 중입니다."
    @Published private(set) var layoutScreenName: String?
    private let settings: SettingsStore
    private let monitor: MonitoringCoordinator
    private let updates: UpdateService
    private enum Slot: Hashable {
        case combined
        case unit(MenuBarUnit)
        var unit: MenuBarUnit? {
            if case .unit(let unit) = self { return unit }; return nil
        }
    }
    private var statusItems: [Slot: NSStatusItem] = [:]
    private var started = false
    private var registrationID = UUID().uuidString
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
        let grouping: MenuBarGrouping
        let values: MenuBarValuePreferences
    }
    private var layoutConfiguration: LayoutConfiguration?
    private var anchorSlot: Slot?
    private var selectedMetrics: [Metric]?
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
    func stop() {
        started = false
        subscriptions.removeAll()
        layoutTask?.cancel()
        popover.performClose(nil)
        for item in statusItems.values { removeStatusItem(item) }
        statusItems.removeAll()
    }
    private func removeStatusItem(_ item: NSStatusItem) {
        NSStatusBar.system.removeStatusItem(item)
        // Discard this layout's saved position instead of accumulating temporary identities.
        item.autosaveName = nil
    }
    private func scheduleButtonUpdate() {
        guard started, !buttonUpdateQueued else { return }
        buttonUpdateQueued = true
        // ObservableObject publishes before mutation. Coalesce all metrics from one sampling pass.
        Task { @MainActor [weak self] in
            guard let self, self.started else { return }
            self.buttonUpdateQueued = false
            self.updateButton()
        }
    }
    private func updateButton() {
        let nextLayout = LayoutConfiguration(order: settings.configuration.order,
            enabled: settings.configuration.enabled, priority: settings.menuBarPriority,
            mode: settings.menuBarDisplayMode, density: settings.menuBarDensity,
            grouping: settings.configuration.menuBarGrouping, values: settings.menuBarValues)
        if layoutConfiguration != nextLayout {
            automaticLimit = nil
            expansionGate = MenuBarExpansionGate()
            layoutConfiguration = nextLayout
            if settings.menuBarDensity == .automatic { layoutMessage = "메뉴바 위치를 확인하는 중입니다." }
        }
        let visible = settings.menuBarDensity.metrics(configuration: settings.configuration,
            priority: settings.menuBarPriority, automaticLimit: automaticLimit)
        let units = settings.configuration.menuBarGrouping.units(metrics: visible)
        let slots: [Slot] = settings.menuBarDisplayMode == .combined || visible.isEmpty
            ? [.combined] : units.map(Slot.unit)
        let groupingChanged = Set(statusItems.keys) != Set(slots)
        let orderChanged = placementOrder != settings.configuration.order
        let selectionChanged = displayedMetrics != visible
        if orderChanged || selectionChanged || groupingChanged || displayMode != settings.menuBarDisplayMode || anchorSlot.map({ !slots.contains($0) }) == true {
            if popover.isShown { popover.performClose(nil) }
        }
        displayMode = settings.menuBarDisplayMode
        if orderChanged || selectionChanged || groupingChanged {
            for item in statusItems.values { removeStatusItem(item) }
            statusItems.removeAll()
            registrationID = UUID().uuidString
            placementOrder = settings.configuration.order
        }
        if displayedMetrics != visible { displayedMetrics = visible }
        if visible.isEmpty { layoutMessage = "모니터링할 항목을 선택하세요." }
        for slot in Array(statusItems.keys) where !slots.contains(slot) {
            if let item = statusItems.removeValue(forKey: slot) { removeStatusItem(item) }
        }
        // New items enter from the left: create in reverse to preserve the settings order left to right.
        // Configured order owns each new layout. A fresh identity prevents macOS from
        // restoring old per-item positions after pairs are split or regrouped.
        MenuBarItemRegistration.update(slots: slots, items: &statusItems, create: { slot in
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = nil
            item.autosaveName = "Lookout.configured.\(registrationID).\(slot.unit?.id ?? "combined")"
            item.button?.target = self
            item.button?.action = #selector(togglePanel(_:))
            item.button?.setAccessibilityIdentifier("lookout-status-\(slot.unit?.id ?? "combined")")
            return item
        }, configure: { slot, item in
            self.updatePresentation(item: item, slot: slot, visible: visible)
            // Enabled display settings own visibility, including a newly split SSD item.
            if !item.isVisible { item.isVisible = true }
        })
        scheduleLayoutCheck()
    }
    private func updatePresentation(item: NSStatusItem, slot: Slot, visible: [Metric]) {
        guard let button = item.button else { return }
        let metrics = slot.unit?.metrics ?? visible
        let monitored = slot.unit == nil ? settings.configuration.enabled : Set(metrics)
        let alerting = Set(monitor.activeAlerts.map(\.metric)).intersection(monitored)
        let hasAlert = !alerting.isEmpty
        if metrics.isEmpty {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Lookout · 모니터링 꺼짐")
            button.subviews.compactMap { $0 as? MenuBarAccentOverlay }.forEach { $0.removeFromSuperview() }
        } else {
            let presentation = MenuBarRenderer.presentation(metrics: metrics, readings: monitor.readings,
                showAlertSlot: settings.alerts.hasEnabledRules(monitored: monitored),
                hasAlert: hasAlert, compact: slot.unit != nil,
                grouping: settings.configuration.menuBarGrouping, values: settings.menuBarValues, alerting: alerting)
            button.image = presentation.image
            var pressure: MemoryPressure?
            if case .memory(let memory) = monitor.readings[.memory]?.value { pressure = memory.pressure }
            button.layoutSubtreeIfNeeded()
            MenuBarAccentOverlay.update(button: button, presentation: presentation,
                                        pressure: pressure, storageMode: settings.menuBarValues.storage)
        }
        button.toolTip = (slot.unit.map { "Lookout · \($0.title)" } ?? "Lookout · 전체 모니터링")
            + "\n" + accessibilityValue(metrics: metrics)
        button.setAccessibilityLabel(slot.unit.map { "Lookout \($0.title)" } ?? "Lookout 모니터링")
        button.setAccessibilityValue(accessibilityValue(metrics: metrics))
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
        let ranked = settings.configuration.menuBarGrouping.rankedUnits(
            configuration: settings.configuration, priority: settings.menuBarPriority)
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
        let limit = expansionGate.resolve(target: target, current: settings.configuration.menuBarGrouping.units(metrics: displayedMetrics).count,
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
            case .memory(let memory):
                text = "\(settings.menuBarValues.memory.title) \(settings.menuBarValues.text(for: .memory, value: value)), 메모리 압력 \(memory.pressure?.title ?? "확인 불가")"
            case .storage:
                text = "\(settings.menuBarValues.storage.title) \(settings.menuBarValues.text(for: .ssd, value: value))"
            case .network(let network): text = "다운로드 \(ValueFormat.rate(network.download)), 업로드 \(ValueFormat.rate(network.upload))"
            case .disk(let disk): text = "읽기 \(disk.activity.map { ValueFormat.rate($0.read) } ?? "—"), 쓰기 \(disk.activity.map { ValueFormat.rate($0.write) } ?? "—")"
            case .power(let energy): text = energy.watts.map(ValueFormat.watts) ?? "—"
            default: text = value?.primary.map(ValueFormat.percent) ?? "—"
            }
            let warning = monitor.activeAlerts.contains { $0.metric == metric } ? " · 경고" : ""
            return "\(metric.title) \(text)\(warning)"
        }.joined(separator: ", ")
    }
    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        guard let slot = statusItems.first(where: { $0.value.button === sender })?.key else { return }
        if popover.isShown, anchorSlot == slot, selectedMetrics == slot.unit?.metrics {
            popover.performClose(nil)
        } else {
            showPanel(anchoredTo: slot, metrics: slot.unit?.metrics)
        }
    }
    func showPanel() {
        // Menu command / notification opens the complete panel, even in individual mode.
        let candidates: [Slot] = [.combined] + settings.configuration.menuBarGrouping.units(metrics: displayedMetrics).map(Slot.unit)
        guard let slot = candidates.first(where: { statusItems[$0]?.button?.window?.screen != nil }) else { return }
        showPanel(anchoredTo: slot, metrics: nil)
    }
    private func showPanel(anchoredTo slot: Slot, metrics: [Metric]?) {
        guard let button = statusItems[slot]?.button else { return }
        if popover.isShown {
            if anchorSlot == slot, selectedMetrics == metrics { popover.contentViewController?.view.window?.makeKey(); return }
            popover.performClose(nil)
        }
        anchorSlot = slot
        selectedMetrics = metrics
        presented = true
        presentationID = UUID()
        let token = presentationID
        let screenHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 720
        let host = NSHostingController(rootView: StatusPopoverContent(owner: self, monitor: monitor, settings: settings,
            screenHeight: screenHeight, selectedMetrics: metrics, resize: { [weak self] size in
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
        selectedMetrics = nil
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
    let selectedMetrics: [Metric]?
    let resize: (CGSize) -> Void
    var body: some View {
        MonitorPanel(monitor: monitor, settings: settings, notifications: monitor.notifications,
                     onOpenSettings: { owner.showSettings() }, onSizeChange: resize,
                     presented: owner.presented, initialScreenHeight: screenHeight, selectedMetrics: selectedMetrics)
    }
}
