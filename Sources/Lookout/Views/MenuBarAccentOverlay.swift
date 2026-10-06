import AppKit
import LookoutCore

/// macOS supplies the template text color; this transparent layer draws only colored accents.
/// Its hit testing and accessibility are disabled so the status button retains all interaction.
@MainActor final class MenuBarAccentOverlay: NSView {
    private var presentation: MenuBarRenderer.Presentation?
    private var pressure: MemoryPressure?
    private var storageMode: CapacityMenuBarValue = .available
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        Self.paint(presentation: presentation, pressure: pressure, storageMode: storageMode)
    }
    static func paint(presentation: MenuBarRenderer.Presentation, pressure: MemoryPressure?, storageMode: CapacityMenuBarValue) {
        for value in presentation.highlightedValues { MenuBarRenderer.draw(value, color: .systemRed) }
        if let frame = presentation.pressureFrame {
            let color: NSColor
            switch pressure {
            case .normal: color = .systemGreen
            case .warning: color = .systemYellow
            case .critical: color = .systemRed
            case nil: color = .secondaryLabelColor
            }
            drawDot(frame: frame, color: color)
        }
        if let frame = presentation.storageFrame {
            switch storageMode {
            case .available, .availablePercentage: drawDot(frame: frame, color: .systemCyan)
            case .used, .percentage: break
            }
        }
    }
    private static func drawDot(frame: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
    static func update(button: NSStatusBarButton, presentation: MenuBarRenderer.Presentation,
                       pressure: MemoryPressure?, storageMode: CapacityMenuBarValue) {
        let existing = button.subviews.compactMap { $0 as? MenuBarAccentOverlay }.first
        guard presentation.pressureFrame != nil || presentation.storageFrame != nil || !presentation.highlightedValues.isEmpty else {
            existing?.removeFromSuperview(); return
        }
        let view = existing ?? MenuBarAccentOverlay(frame: .zero)
        var imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        if imageRect.width <= 0 || imageRect.height <= 0 {
            imageRect = NSRect(x: (button.bounds.width - presentation.image.size.width) / 2,
                               y: (button.bounds.height - presentation.image.size.height) / 2,
                               width: presentation.image.size.width, height: presentation.image.size.height)
        }
        view.frame = imageRect
        view.bounds = NSRect(origin: .zero, size: presentation.image.size)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        view.presentation = presentation; view.pressure = pressure; view.storageMode = storageMode
        view.needsDisplay = true
        view.setAccessibilityElement(false)
        if existing == nil { button.addSubview(view) }
    }
}
