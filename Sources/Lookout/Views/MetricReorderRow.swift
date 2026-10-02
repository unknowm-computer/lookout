import LookoutCore
import SwiftUI
enum MetricOrderScope: String { case placement, priority }

/// Only the handle starts a drag, leaving checkboxes and graph pickers independently usable.
struct MetricReorderRow<Content: View>: View {
    let metric: Metric
    let scope: MetricOrderScope
    let order: [Metric]
    var alignment: VerticalAlignment = .top
    let move: (Metric, Metric) -> Void
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: (DragGesture.Value) -> Void
    let dragCancelled: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false
    @State private var cancelled = false
    @GestureState private var dragging = false
    @FocusState private var handleFocused: Bool

    var body: some View {
        HStack(alignment: alignment, spacing: 8) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .padding(6)
                .background(isHovered ? Color.primary.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .focusable()
                .focused($handleFocused)
                .focusEffectDisabled(dragging)
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(scope))
                    .updating($dragging) { _, active, _ in active = true }
                    .onChanged { value in
                        guard !cancelled else { return }
                        handleFocused = true
                        dragChanged(value)
                    }
                    .onEnded { value in
                        if !cancelled { dragEnded(value) }
                        cancelled = false
                        handleFocused = false
                    })
                .onChange(of: dragging) { _, active in
                    if !active { dragCancelled(); cancelled = false; handleFocused = false }
                }
                .onKeyPress(.escape) {
                    guard dragging else { return .ignored }
                    cancelled = true
                    dragCancelled()
                    return .handled
                }
                .help("드래그하여 순서 변경 · Esc로 취소")
                .accessibilityLabel("\(metric.title) 순서 변경")
                .accessibilityAction(named: Text("위로 이동")) { moveBy(-1) }
                .accessibilityAction(named: Text("아래로 이동")) { moveBy(1) }
                .contextMenu {
                    Button("위로 이동") { moveBy(-1) }.disabled(metric == order.first)
                    Button("아래로 이동") { moveBy(1) }.disabled(metric == order.last)
                }
        }
        .padding(7)
    }

    private func moveBy(_ offset: Int) {
        guard let index = order.firstIndex(of: metric), order.indices.contains(index + offset) else { return }
        move(metric, order[index + offset])
    }
}
