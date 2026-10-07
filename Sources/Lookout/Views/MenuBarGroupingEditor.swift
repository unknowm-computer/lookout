import LookoutCore
import SwiftUI

/// Drag previews remain local; neither defaults nor status items change before release.
struct MenuBarGroupingEditor: View {
    let grouping: MenuBarGrouping
    let order: [Metric]
    let enabled: Set<Metric>
    let supported: Set<Metric>
    let change: (MenuBarGrouping) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [Metric: CGRect] = [:]
    @State private var cardFrames: [MenuBarUnit: CGRect] = [:]
    @State private var detachFrame = CGRect.zero
    @State private var boardSize = CGSize.zero
    @State private var session: MenuBarPairingSession?
    private let coordinateSpace = "menu-bar-pairing"
    private var animation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.16) }
    private var units: [MenuBarUnit] { grouping.units(metrics: order.filter(MenuBarGrouping.eligible.contains)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("항목 그룹화")).font(.system(size: 13, weight: .semibold))
            Text(L10n.text("항목을 다른 항목 위로 드래그하여 두 줄로 묶습니다."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            board
            Text(L10n.text("그룹 안에서 드래그하면 순서 교환 · 밖으로 꺼내면 해제 · Esc로 취소"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("네트워크·디스크 I/O는 별도로 표시합니다. 모니터링을 끈 항목의 그룹 설정은 유지됩니다."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: grouping) { _, _ in session = nil }
        .onChange(of: order) { _, _ in session = nil }
        .onChange(of: enabled) { _, _ in session = nil }
        .onChange(of: supported) { _, _ in session = nil }
        .onDisappear { session = nil }
    }

    private var board: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(units, id: \.id) { unit in card(unit) }
            }
            .padding(.horizontal, 6).padding(.top, 6)
            Text(dragHint)
                .font(.system(size: 10)).foregroundStyle(session?.detaching == true ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Color.accentColor.opacity(session?.detaching == true ? 0.08 : 0.02),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(
                    Color.accentColor.opacity(session?.detaching == true ? 0.65 : 0.2),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                .background { GeometryReader { geometry in
                    Color.clear.preference(key: PairingDetachFrame.self,
                        value: geometry.frame(in: .named(coordinateSpace)))
                } }
        }
        .coordinateSpace(name: coordinateSpace)
        .background { GeometryReader { geometry in
            Color.clear.preference(key: PairingBoardSize.self, value: geometry.size)
        } }
        .onPreferenceChange(PairingMetricFrames.self) { frames = $0 }
        .onPreferenceChange(PairingCardFrames.self) { cardFrames = $0 }
        .onPreferenceChange(PairingDetachFrame.self) { detachFrame = $0 }
        .onPreferenceChange(PairingBoardSize.self) { boardSize = $0 }
        .overlay(alignment: .topLeading) {
            if let session, let origin = session.frames[session.source] {
                tokenLabel(session.source)
                    .frame(width: origin.width, height: origin.height)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.5)) }
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    .opacity(0.85)
                    .position(x: origin.midX + session.translation.width, y: origin.midY + session.translation.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("menu-bar-grouping-editor")
    }

    private func card(_ unit: MenuBarUnit) -> some View {
        let highlighted = session?.target.map(unit.metrics.contains) ?? false
        let preview = highlighted ? session?.preview : nil
        let metrics = session.flatMap { preview?.pair(containing: $0.source)?.metrics } ?? unit.metrics
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(metrics) { metric in
                PairingToken(metric: metric, supported: supported.contains(metric),
                             label: { tokenLabel(metric) },
                             changed: { update(metric, value: $0) },
                             ended: { finish(metric, value: $0) },
                             cancelled: { session = nil },
                             menu: { actions(for: metric) })
                    .background { GeometryReader { geometry in
                        // Preview-only rows must not overwrite the actual source's hit-test frame.
                        Color.clear.preference(key: PairingMetricFrames.self,
                            value: unit.metrics.contains(metric) ? [metric: geometry.frame(in: .named(coordinateSpace))] : [:])
                    } }
                    .opacity(session?.source == metric && !highlighted ? 0.25 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(6).frame(maxWidth: .infinity).frame(height: 64)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(
            highlighted ? Color.accentColor : Color.primary.opacity(unit.metrics.count == 2 ? 0.2 : 0.1),
            lineWidth: highlighted ? 2 : 0.5) }
        .overlay(alignment: .topTrailing) {
            if unit.metrics.count == 2 {
                Button { change(grouping.removing(unit.metrics[0])) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .medium))
                        .frame(width: 18, height: 10)
                }
                .buttonStyle(PanelActionButtonStyle(borderless: true, horizontalPadding: 0))
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
                .accessibilityLabel(L10n.text("\(unit.title) 그룹 해제")).help(L10n.text("그룹 해제"))
                .offset(x: 6, y: -6)
            }
        }
        .background { GeometryReader { geometry in
            Color.clear.preference(key: PairingCardFrames.self,
                value: [unit: geometry.frame(in: .named(coordinateSpace))])
        } }
        .animation(animation, value: session?.target)
    }

    private func tokenLabel(_ metric: Metric) -> some View {
        HStack(spacing: 4) {
            Image(systemName: metric.symbol).font(.system(size: 10)).frame(width: 12)
            Text(metric == .memory ? "RAM" : metric.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(enabled.contains(metric) && supported.contains(metric) ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity).frame(height: 24)
    }
    private var dragHint: String {
        if session?.detaching == true { return L10n.text("놓으면 그룹이 해제됩니다") }
        if let session, let target = session.target {
            if grouping.pair(containing: session.source)?.metrics.contains(target) == true { return L10n.text("놓으면 두 줄 순서가 바뀝니다") }
            return L10n.text("놓으면 \(session.source.title) / \(target.title)로 묶입니다")
        }
        return L10n.text("그룹에서 항목을 꺼내 여기에 놓으면 해제됩니다")
    }

    @ViewBuilder private func actions(for metric: Metric) -> some View {
        if grouping.pair(containing: metric) != nil {
            Button(L10n.text("두 줄 순서 교환")) { change(grouping.swapping(metric)) }
            Button(L10n.text("그룹 해제")) { change(grouping.removing(metric)) }
        }
        ForEach(MenuBarGrouping.eligible.filter {
            $0 != metric && supported.contains($0) && grouping.pair(containing: metric)?.metrics.contains($0) != true
        }) { target in
            Button(L10n.text("\(target.title)와 묶기")) { change(grouping.pairing(metric, with: target)) }
        }
    }

    private func update(_ metric: Metric, value: DragGesture.Value) {
        guard supported.contains(metric) else { return }
        if session == nil {
            session = MenuBarPairingSession(source: metric, original: grouping, frames: frames,
                detachFrame: detachFrame, boardSize: boardSize, supported: supported, targetFrames: dropTargets)
        }
        guard session?.source == metric else { return }
        session?.update(location: value.location, translation: value.translation)
    }
    private var dropTargets: [Metric: CGRect] {
        var result: [Metric: CGRect] = [:]
        for unit in units {
            guard let frame = cardFrames[unit] else { continue }
            if unit.metrics.count == 1 { result[unit.metrics[0]] = frame }
            else {
                let upper = unit.metrics[0], lower = unit.metrics[1]
                let boundary = (frames[upper]?.maxY ?? frame.midY) + 2
                result[upper] = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: boundary - frame.minY)
                result[lower] = CGRect(x: frame.minX, y: boundary, width: frame.width, height: frame.maxY - boundary)
            }
        }
        return result
    }
    private func finish(_ metric: Metric, value: DragGesture.Value) {
        guard var current = session, current.source == metric, current.original == grouping else { session = nil; return }
        current.update(location: value.location, translation: value.translation)
        withAnimation(animation) {
            session = nil
            if let preview = current.preview, preview != grouping { change(preview) }
        }
    }
}

/// Frozen geometry avoids chasing animated preview rows. A preview has no side effects.
struct MenuBarPairingSession {
    let source: Metric
    let original: MenuBarGrouping
    let frames: [Metric: CGRect]
    let detachFrame: CGRect
    let boardSize: CGSize
    let supported: Set<Metric>
    var targetFrames: [Metric: CGRect] = [:]
    var translation = CGSize.zero
    private(set) var target: Metric?
    private(set) var detaching = false
    private(set) var preview: MenuBarGrouping?

    mutating func update(location: CGPoint, translation: CGSize) {
        self.translation = translation; target = nil; detaching = false; preview = nil
        guard supported.contains(source), frames[source] != nil else { return }
        if let target = MenuBarGrouping.eligible.first(where: {
            $0 != source && supported.contains($0) && (targetFrames[$0] ?? frames[$0])?.contains(location) == true
        }) {
            let next = original.pairing(source, with: target)
            if next != original { self.target = target; preview = next }
        } else if original.pair(containing: source) != nil,
                  detachFrame.contains(location) || !CGRect(origin: .zero, size: boardSize).contains(location) {
            detaching = true; preview = original.removing(source)
        }
    }
}

private struct PairingToken<Label: View, MenuContent: View>: View {
    let metric: Metric
    let supported: Bool
    @ViewBuilder let label: () -> Label
    let changed: (DragGesture.Value) -> Void
    let ended: (DragGesture.Value) -> Void
    let cancelled: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var hovered = false
    @State private var wasCancelled = false
    @GestureState private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        label()
            .background(Color.primary.opacity(hovered && supported ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle()).onHover { hovered = $0 }
            // Do not make idle drag targets part of the window's keyboard focus order.
            .focusable(supported && dragging).focused($focused).focusEffectDisabled()
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("menu-bar-pairing"))
                .updating($dragging) { _, active, _ in if supported { active = true } }
                .onChanged { value in
                    guard supported, !wasCancelled else { return }
                    focused = true; changed(value)
                }
                .onEnded { value in
                    if supported && !wasCancelled { ended(value) }
                    wasCancelled = false; focused = false
                })
            .onChange(of: dragging) { _, active in
                if active { focused = true }
                else { cancelled(); wasCancelled = false; focused = false }
            }
            .onKeyPress(.escape) {
                guard dragging else { return .ignored }
                wasCancelled = true; cancelled(); return .handled
            }
            .contextMenu { if supported { menu() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("\(metric.title) 그룹화"))
            .accessibilityHint(supported ? L10n.text("다른 항목으로 드래그하거나 동작 메뉴에서 그룹을 선택합니다.") : L10n.text("이 Mac에서는 지원하지 않습니다."))
            .accessibilityActions { if supported { menu() } }
            .help(supported ? L10n.text("드래그하여 그룹화 · 보조 클릭으로 동작 메뉴 · Esc로 취소") : L10n.text("이 Mac에서는 지원하지 않습니다."))
    }
}

private struct PairingMetricFrames: PreferenceKey {
    static let defaultValue: [Metric: CGRect] = [:]
    static func reduce(value: inout [Metric: CGRect], nextValue: () -> [Metric: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct PairingCardFrames: PreferenceKey {
    static let defaultValue: [MenuBarUnit: CGRect] = [:]
    static func reduce(value: inout [MenuBarUnit: CGRect], nextValue: () -> [MenuBarUnit: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct PairingDetachFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct PairingBoardSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
