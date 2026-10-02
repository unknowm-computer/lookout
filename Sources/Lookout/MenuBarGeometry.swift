import AppKit
import LookoutCore

/// Status-item content is shared by the menu bars on connected displays. Measure our own
/// AppKit buttons, then translate their distance from the right edge to the screen in use.
/// No screen capture or accessibility permission is needed.
@MainActor enum MenuBarGeometry {
    struct Measurement {
        let available: Double
        let padding: Double
        let gap: Double
        let frames: [NSRect]
        let screenName: String
    }
    static func measure(_ buttons: [NSStatusBarButton], preferredScreen: NSScreen? = nil) -> Measurement? {
        let samples = buttons.compactMap { button -> (NSRect, NSScreen, Double)? in
            guard let window = button.window, let image = button.image else { return nil }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            guard rect.width > 0, rect.minX.isFinite, rect.maxX.isFinite,
                  let screen = NSScreen.screens.first(where: {
                      abs(rect.maxY - $0.frame.maxY) <= NSStatusBar.system.thickness + 8 &&
                      rect.midX >= $0.frame.minX && rect.midX <= $0.frame.maxX
                  }) else { return nil }
            return (rect, screen, max(0, rect.width - image.size.width))
        }
        guard let sample = samples.first else { return nil }
        let frames = samples.filter { $0.1 == sample.1 }.map(\.0).sorted { $0.minX < $1.minX }
        guard let rightEdge = frames.map(\.maxX).max() else { return nil }
        let rightInset = max(0, sample.1.frame.maxX - rightEdge)
        // NSScreen.main can describe our settings window rather than the user's active display.
        // The pointer gives an explicit, predictable screen choice even with no Lookout window.
        let target = preferredScreen ?? NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? sample.1
        let safeMinX = target.auxiliaryTopRightArea?.minX ?? target.frame.minX
        guard let budget = MenuBarSpacePolicy.availableWidth(screenMinX: Double(target.frame.minX),
            screenMaxX: Double(target.frame.maxX), safeMinX: Double(safeMinX),
            rightInset: Double(rightInset)) else { return nil }
        let gaps = zip(frames, frames.dropFirst()).map { max(0, $1.minX - $0.maxX) }
        return Measurement(available: budget,
                           padding: samples.map(\.2).max() ?? 0,
                           gap: gaps.min() ?? 0, frames: frames, screenName: target.localizedName)
    }
}
