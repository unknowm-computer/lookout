import AppKit
import LookoutCore
import SwiftUI

/// Preview is local to this list; saved settings and menu-bar items change only after release.
struct MetricReorderList<Content: View>: View {
    let scope: MetricOrderScope
    let order: [Metric]
    var spacing: CGFloat = 0
    var separators = false
    var alignment: VerticalAlignment = .center
    var footnote: (Metric) -> String? = { _ in nil }
    let move: (Metric, Metric) -> Void
    @ViewBuilder let content: (Metric, Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredFrames: [Metric: CGRect] = [:]
    @State private var session: MetricReorderSession?

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.18) }
    private var finishingID: UUID? { session?.finishing == true ? session?.id : nil }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(order.enumerated()), id: \.element) { index, metric in
                VStack(spacing: 0) {
                    row(metric, index: session?.preview.firstIndex(of: metric) ?? index)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: MetricRowFrames.self,
                                    value: [metric: geometry.frame(in: .named(scope))])
                            }
                        }
                        .opacity(session?.metric == metric ? 0 : 1)
                        .offset(y: offset(for: metric))
                        .animation(animation, value: session?.preview)
                    if separators && index < order.count - 1 {
                        Divider().padding(.horizontal, 11).opacity(session == nil ? 1 : 0)
                    }
                }
            }
        }
        .coordinateSpace(name: scope)
        .onPreferenceChange(MetricRowFrames.self) { measuredFrames = $0 }
        .overlay(alignment: .topLeading) {
            Group {
                if let session, let target = session.layout[session.metric],
                   let origin = session.frames[session.metric] {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                        .animation(animation, value: session.preview)
                    row(session.metric, index: session.preview.firstIndex(of: session.metric) ?? 0)
                        .frame(width: origin.width, height: origin.height)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                        .position(x: origin.midX, y: origin.midY + session.translation)
                        .animation(animation, value: session.finishing)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: order) { _, _ in cancel() }
        .onDisappear { cancel() }
        .task(id: finishingID) {
            guard let id = finishingID else { return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            guard let current = session, current.id == id, current.finishing, current.original == order else { return }
            let index = current.preview.firstIndex(of: current.metric)
            // Animated offsets already match the destination. Avoid animating the saved layout a second time.
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                session = nil
                if let index, current.preview != order { move(current.metric, order[index]) }
            }
        }
    }

    @ViewBuilder private func row(_ metric: Metric, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricReorderRow(metric: metric, scope: scope, order: order, alignment: alignment, move: move,
                             dragChanged: { update(metric, value: $0) },
                             dragEnded: { finish(metric, value: $0) },
                             dragCancelled: { if session?.finishing != true { cancel() } }) {
                content(metric, index)
            }
            if let text = footnote(metric) {
                Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.bottom, 8)
            }
        }
    }

    private func offset(for metric: Metric) -> CGFloat {
        guard let session, metric != session.metric,
              let original = session.frames[metric], let target = session.layout[metric] else { return 0 }
        return target.minY - original.minY
    }

    private func update(_ metric: Metric, value: DragGesture.Value) {
        if session == nil {
            guard order.allSatisfy({ measuredFrames[$0] != nil }) else { return }
            session = MetricReorderSession(metric: metric, original: order, frames: measuredFrames)
        }
        guard var next = session, next.metric == metric, !next.finishing,
              let frame = next.frames[metric] else { return }
        next.translation = value.translation.height
        let center = frame.midY + next.translation
        // Cross adjacent midpoints. The snapshot avoids chasing frames while neighboring rows animate.
        while let index = next.preview.firstIndex(of: metric), index > 0,
              let previous = next.layout[next.preview[index - 1]], center < previous.midY {
            next.preview = MetricOrdering.moving(metric, to: next.preview[index - 1], in: next.preview)
        }
        while let index = next.preview.firstIndex(of: metric), index < next.preview.count - 1,
              let following = next.layout[next.preview[index + 1]], center > following.midY {
            next.preview = MetricOrdering.moving(metric, to: next.preview[index + 1], in: next.preview)
        }
        session = next
    }

    private func finish(_ metric: Metric, value: DragGesture.Value) {
        update(metric, value: value)
        guard var next = session, let first = next.original.first, let last = next.original.last,
              let top = next.frames[first], let bottom = next.frames[last],
              value.location.x >= top.minX, value.location.x <= top.maxX,
              value.location.y >= top.minY, value.location.y <= bottom.maxY,
              let target = next.layout[metric], let origin = next.frames[metric] else { cancel(); return }
        next.translation = target.midY - origin.midY
        next.finishing = true
        session = next
    }

    private func cancel() { withAnimation(animation) { session = nil } }
}

private struct MetricRowFrames: PreferenceKey {
    static let defaultValue: [Metric: CGRect] = [:]
    static func reduce(value: inout [Metric: CGRect], nextValue: () -> [Metric: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MetricReorderSession {
    let id = UUID()
    let metric: Metric
    let original: [Metric]
    let frames: [Metric: CGRect]
    var preview: [Metric]
    var translation: CGFloat = 0
    var finishing = false

    init(metric: Metric, original: [Metric], frames: [Metric: CGRect]) {
        self.metric = metric; self.original = original; self.frames = frames; preview = original
    }

    var layout: [Metric: CGRect] {
        guard let first = original.first, let firstFrame = frames[first] else { return [:] }
        let gap: CGFloat
        if original.count > 1, let second = frames[original[1]] { gap = second.minY - firstFrame.maxY }
        else { gap = 0 }
        var y = firstFrame.minY
        var result: [Metric: CGRect] = [:]
        for metric in preview {
            guard var frame = frames[metric] else { continue }
            frame.origin.y = y; result[metric] = frame; y += frame.height + gap
        }
        return result
    }
}
