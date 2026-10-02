import AppKit
import SwiftUI

/// Resolve the display containing this panel, including a secondary display's menu bar.
struct PanelScreenReader: NSViewRepresentable {
    let onHeightChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.onHeightChange = onHeightChange
        return view
    }
    func updateNSView(_ view: ScreenView, context: Context) {
        view.onHeightChange = onHeightChange
        view.refreshScreen()
    }
    static func dismantleNSView(_ view: ScreenView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.onHeightChange = nil
    }

    final class ScreenView: NSView {
        var onHeightChange: ((CGFloat) -> Void)?
        private var lastHeight: CGFloat?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResizeNotification] {
                center.addObserver(self, selector: #selector(refreshScreen), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(refreshScreen),
                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
            refreshScreen()
        }
        @objc func refreshScreen() {
            guard let screen = window?.screen else { return }
            let height = screen.visibleFrame.height
            guard height > 0, lastHeight != height else { return }
            lastHeight = height
            // SwiftUI may be updating the representable when the view first attaches to its window.
            Task { @MainActor [weak self] in self?.onHeightChange?(height) }
        }
    }
}
