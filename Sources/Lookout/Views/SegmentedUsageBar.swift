import LookoutCore
import SwiftUI

struct UsageBarSegment: Identifiable {
    let id: String
    let title: String
    let fraction: Double
    let color: Color
    let summary: String
}

/// RAM, Swap and SSD share geometry, hover timing and tooltip placement.
struct SegmentedUsageBar: View {
    let segments: [UsageBarSegment]
    let accessibilityTitle: String
    @State private var hoveredID: String?
    @State private var pointerX: CGFloat = 0
    @State private var tooltipVisible = false
    @State private var tooltipWidth: CGFloat = 220
    private var hoveredSegment: UsageBarSegment? { segments.first { $0.id == hoveredID } }

    var body: some View {
        GeometryReader { geometry in
            if !segments.isEmpty {
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.color)
                            .frame(width: geometry.size.width * bounded(segment.fraction))
                            .accessibilityLabel(segment.title)
                            .accessibilityValue(segment.summary)
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointerX = location.x
                        hoveredID = segmentID(at: location.x, width: geometry.size.width)
                    case .ended:
                        dismissTooltip()
                    }
                }
                .onChange(of: segments.map(\.fraction)) { _, _ in
                    if hoveredID != nil { hoveredID = segmentID(at: pointerX, width: geometry.size.width) }
                }
                .overlay(alignment: .topLeading) {
                    if tooltipVisible, let hoveredSegment {
                        UsageTooltip(summary: hoveredSegment.summary)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tooltipWidth = $0 }
                            .position(x: tooltipX(width: geometry.size.width), y: -16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityTitle)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16))
                    .accessibilityLabel(L10n.text("\(accessibilityTitle) · 측정값 없음"))
            }
        }.frame(height: 13)
            .zIndex(1)
            .task(id: hoveredID) {
                guard hoveredID != nil, !tooltipVisible else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled, hoveredID != nil else { return }
                tooltipVisible = true
            }
            .onChange(of: segments.isEmpty) { _, missing in if missing { dismissTooltip() } }
            .onDisappear { dismissTooltip() }
    }
    private func bounded(_ fraction: Double) -> Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
    private func segmentID(at x: CGFloat, width: CGFloat) -> String? {
        guard width > 0, x >= 0, x <= width else { return nil }
        var edge: CGFloat = 0
        for segment in segments {
            edge += width * bounded(segment.fraction)
            if x < edge { return segment.id }
        }
        return x == width ? segments.last(where: { bounded($0.fraction) > 0 })?.id : nil
    }
    private func tooltipX(width: CGFloat) -> CGFloat {
        guard tooltipWidth < width else { return width / 2 }
        return min(width - tooltipWidth / 2, max(tooltipWidth / 2, pointerX))
    }
    private func dismissTooltip() {
        hoveredID = nil
        tooltipVisible = false
    }
}
