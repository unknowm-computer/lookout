import AppKit
import SwiftUI

struct WindowLayoutPreviewTooltip: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) { anchor.show(image) }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.hide() }

    final class Anchor: NSView {
        private var tooltip: NSPanel?
        private var displayedImage: CGImage?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { hide() }
            super.viewWillMove(toWindow: newWindow)
        }

        func show(_ image: CGImage?) {
            guard let image, let window, let screen = window.screen else { hide(); return }
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let visible = window.convertToScreen(window.contentLayoutRect)
                .intersection(screen.visibleFrame).insetBy(dx: 4, dy: 4)
            let gap: CGFloat = 6
            let verticalRoom = max(visible.maxY - anchor.maxY - gap, anchor.minY - visible.minY - gap)
            guard visible.width > 12, verticalRoom > 12 else { hide(); return }
            let scale = min(min(320, visible.width - 12) / CGFloat(image.width),
                            min(180, verticalRoom - 12) / CGFloat(image.height))
            let imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let size = CGSize(width: imageSize.width + 12, height: imageSize.height + 12)
            let origin = position(size: size, anchor: anchor, visible: visible, gap: gap)
            if displayedImage === image, let tooltip, tooltip.frame.size == size {
                tooltip.setFrame(CGRect(origin: origin, size: size), display: true)
                return
            }
            hide()

            let content = Image(decorative: image, scale: 1)
                .resizable().frame(width: imageSize.width, height: imageSize.height)
                .clipShape(.rect(cornerRadius: 4))
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
            let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
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

        private func position(size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat) -> CGPoint {
            // Align with the leading icon, not the edge of the containing window.
            let x = min(max(anchor.minX, visible.minX), visible.maxX - size.width)
            let above = anchor.maxY + gap
            let below = anchor.minY - gap - size.height
            let y = above + size.height <= visible.maxY ? above : max(visible.minY, below)
            return CGPoint(x: x, y: y)
        }
    }
}
