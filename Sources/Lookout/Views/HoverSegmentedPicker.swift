import AppKit
import SwiftUI

struct SegmentOption<Value: Hashable> {
    let value: Value
    let title: String
}

/// Native segmented pickers do not expose per-segment hover styling.
struct HoverSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SegmentOption<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segmentButton(option)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func segmentButton(_ option: SegmentOption<Value>) -> some View {
        Button { selection = option.value } label: {
            Text(option.title).frame(maxWidth: .infinity)
        }
        .buttonStyle(SegmentButtonStyle(selected: selection == option.value))
        .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        SegmentButtonBody(configuration: configuration, selected: selected)
    }
}

private struct SegmentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    private var highlightOpacity: Double {
        guard isEnabled, !selected else { return 0 }
        if configuration.isPressed { return 0.20 }
        return hovered ? (colorScheme == .dark ? 0.12 : 0.10) : 0
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? (colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor)) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(highlightOpacity))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(selected ? 0.12 : 0), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
            .onDisappear { hovered = false }
    }
}
