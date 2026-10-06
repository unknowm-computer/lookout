import SwiftUI

enum UsageTooltipSpace {
    static let viewport = "monitor-tooltip-viewport"
}

private struct UsageTooltipViewportKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    var usageTooltipViewportSize: CGSize? {
        get { self[UsageTooltipViewportKey.self] }
        set { self[UsageTooltipViewportKey.self] = newValue }
    }
}

enum UsageTooltipPlacement {
    static func center(pointer: CGPoint, size: CGSize, bounds: CGRect, gap: CGFloat = 10) -> CGPoint {
        let x = min(max(bounds.minX, bounds.maxX - size.width), max(bounds.minX, pointer.x - size.width / 2))
        let above = pointer.y - gap - size.height
        let preferredY = above >= bounds.minY ? above : pointer.y + gap
        let y = min(max(bounds.minY, bounds.maxY - size.height), max(bounds.minY, preferredY))
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
}

struct UsageTooltip: View {
    let summary: String
    var body: some View {
        Text(summary)
            .font(.system(size: 10)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
