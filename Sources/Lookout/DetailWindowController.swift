import AppKit
import LookoutCore
import SwiftUI

/// A single detached panel shares the existing sampler and releases view demand on close.
@MainActor final class DetailWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var presented = false
    private let monitor: MonitoringCoordinator
    private let settings: SettingsStore
    private let openSettings: () -> Void
    private var window: NSWindow?
    private var selectedMetrics: [Metric]?
    private var presentationID = UUID()

    init(monitor: MonitoringCoordinator, settings: SettingsStore, openSettings: @escaping () -> Void) {
        self.monitor = monitor; self.settings = settings; self.openSettings = openSettings
        super.init()
    }

    func show(metrics: [Metric]?, screen: NSScreen?, near panelFrame: NSRect?) {
        if let window, selectedMetrics == metrics {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let isNew = window == nil
        let window = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                                       backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = L10n.text("Lookout 상세 정보")
        selectedMetrics = metrics
        presentationID = UUID()
        let token = presentationID
        presented = true
        let host = NSHostingController(rootView: DetachedPanelContent(owner: self, monitor: monitor,
            settings: settings, selectedMetrics: metrics, screenHeight: screen?.visibleFrame.height ?? 720,
            openSettings: openSettings, resize: { [weak self] size in
                Task { @MainActor [weak self] in self?.resize(size, token: token) }
            }))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        if isNew {
            if let screen, let panelFrame {
                let bounds = screen.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: max(bounds.minX, min(panelFrame.minX, bounds.maxX - window.frame.width)),
                    y: max(bounds.minY, min(panelFrame.maxY - window.frame.height, bounds.maxY - window.frame.height))))
            } else {
                window.center()
            }
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resize(_ size: CGSize, token: UUID) {
        guard token == presentationID, presented, let window, size.height.isFinite, size.height > 0 else { return }
        let contentSize = NSSize(width: 340, height: ceil(size.height))
        guard window.contentView?.frame.size != contentSize else { return }
        let top = window.frame.maxY
        window.setContentSize(contentSize)
        var frame = window.frame
        frame.origin.y = max(window.screen?.visibleFrame.minY ?? frame.minY, top - frame.height)
        window.setFrame(frame, display: true)
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        presented = false
        presentationID = UUID()
        window?.contentViewController = nil
        window = nil
        selectedMetrics = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { presented = false }
    func windowDidDeminiaturize(_ notification: Notification) { presented = true }
}

private struct DetachedPanelContent: View {
    @ObservedObject var owner: DetailWindowController
    @ObservedObject var monitor: MonitoringCoordinator
    @ObservedObject var settings: SettingsStore
    let selectedMetrics: [Metric]?
    let screenHeight: CGFloat
    let openSettings: () -> Void
    let resize: (CGSize) -> Void
    var body: some View {
        MonitorPanel(monitor: monitor, settings: settings, notifications: monitor.notifications,
                     onOpenSettings: openSettings, onSizeChange: resize, presented: owner.presented,
                     initialScreenHeight: screenHeight, selectedMetrics: selectedMetrics)
    }
}
