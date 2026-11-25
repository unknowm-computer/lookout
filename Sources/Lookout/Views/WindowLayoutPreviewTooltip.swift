import AppKit
import SwiftUI

struct WindowLayoutPreviewTooltip: NSViewRepresentable {
    enum Presentation {
        case menuBar, settings

        static let padding: CGFloat = 6

        func panelFrame(image: CGSize, anchor: CGRect, window: CGRect, screen: CGRect) -> CGRect? {
            let preferred = CGSize(width: 320, height: 180)
            let inset = 2 * Self.padding
            let gap: CGFloat = 6
            let visible: CGRect
            let viewport: CGSize
            switch self {
            case .menuBar:
                visible = screen.insetBy(dx: 4, dy: 4)
                viewport = CGSize(width: min(preferred.width, visible.width - inset),
                                  height: min(preferred.height, visible.height - inset))
            case .settings:
                visible = window.intersection(screen).insetBy(dx: 4, dy: 4)
                let verticalRoom = max(visible.maxY - anchor.maxY - gap, anchor.minY - visible.minY - gap)
                let scale = min(min(preferred.width, visible.width - inset) / image.width,
                                min(preferred.height, verticalRoom - inset) / image.height)
                viewport = CGSize(width: image.width * scale, height: image.height * scale)
            }
            guard viewport.width > 0, viewport.height > 0 else { return nil }
            let size = CGSize(width: viewport.width + inset, height: viewport.height + inset)
            let x = min(max(anchor.minX, visible.minX), visible.maxX - size.width)
            let above = anchor.maxY + gap
            let below = anchor.minY - gap - size.height
            let y = above + size.height <= visible.maxY ? above : max(visible.minY, below)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    let image: CGImage?
    let presentation: Presentation

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) { anchor.show(image, presentation: presentation) }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.hide() }

    final class Anchor: NSView {
        private var tooltip: NSPanel?
        private var displayedImage: CGImage?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { hide() }
            super.viewWillMove(toWindow: newWindow)
        }

        func show(_ image: CGImage?, presentation: Presentation) {
            guard let image, let window, let screen = window.screen else { hide(); return }
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            guard let frame = presentation.panelFrame(image: CGSize(width: image.width, height: image.height),
                                                      anchor: anchor, window: window.convertToScreen(window.contentLayoutRect),
                                                      screen: screen.visibleFrame) else { hide(); return }
            if displayedImage === image, let tooltip, tooltip.frame.size == frame.size {
                tooltip.setFrame(frame, display: true)
                return
            }
            hide()

            let content = Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
                .padding(Presentation.padding)
                .frame(width: frame.width, height: frame.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.level = window.level
            panel.appearance = window.effectiveAppearance
            panel.contentView = NSHostingView(rootView: content)
            tooltip = panel
            displayedImage = image
            window.addChildWindow(panel, ordered: .above)
        }

        func hide() {
            if let tooltip {
                tooltip.parent?.removeChildWindow(tooltip)
                tooltip.orderOut(nil)
            }
            tooltip = nil
            displayedImage = nil
        }
    }
}
