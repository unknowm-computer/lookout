import SwiftUI

struct UsageGaugeGeometry {
    let center: CGPoint
    let radius: CGFloat
    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height - 5)
        radius = min(size.width / 2 - 7, size.height - 12)
    }
    func segmentID(at point: CGPoint, segments: [UsageBarSegment]) -> String? {
        let dx = point.x - center.x, dy = point.y - center.y
        // A little tolerance around the 7pt arc makes thin segments easier to hover.
        guard radius > 0, abs(hypot(dx, dy) - radius) <= 7, dy <= 3.5 else { return nil }
        let fraction = dy > 0 ? (dx > 0 ? 1.0 : 0.0) : min(1, max(0, atan2(-dy, -dx) / .pi))
        var edge = 0.0
        for segment in segments {
            let width = segment.fraction.isFinite ? min(1 - edge, max(0, segment.fraction)) : 0
            guard width > 0 else { continue }
            edge += width
            if fraction < edge || (fraction == 1 && edge >= 1) { return segment.id }
        }
        return nil
    }
}
