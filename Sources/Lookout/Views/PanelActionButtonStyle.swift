import AppKit
import SwiftUI

/// Shared by panel and settings actions, including settings popovers.
struct PanelActionButtonStyle: ButtonStyle {
    var prominent = false
    var borderless = false
    var horizontalPadding: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        PanelActionButtonBody(configuration: configuration, prominent: prominent, borderless: borderless,
                              horizontalPadding: horizontalPadding)
    }
}

private struct PanelActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let borderless: Bool
    let horizontalPadding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    private var highlightOpacity: Double {
        guard isEnabled else { return 0 }
        if borderless && !prominent {
            if configuration.isPressed { return colorScheme == .dark ? 0.14 : 0.12 }
            return isHovered ? (colorScheme == .dark ? 0.08 : 0.06) : 0
        }
        if configuration.isPressed { return colorScheme == .dark ? 0.22 : 0.20 }
        return isHovered ? (colorScheme == .dark ? 0.12 : 0.10) : 0
    }
    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? (prominent ? Color.white : Color.primary) : Color.secondary)
            .padding(.horizontal, horizontalPadding).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(prominent ? Color.accentColor : (borderless ? Color.clear : (colorScheme == .light ? Color.white : Color(nsColor: .controlBackgroundColor))))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).fill((prominent ? Color.black : Color.primary).opacity(highlightOpacity))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isFocused ? Color.accentColor : (borderless && !prominent ? Color.clear : Color.primary.opacity(0.12)),
                                  lineWidth: isFocused ? 2 : 0.5)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { isHovered = $0 }
            .onChange(of: isEnabled) { _, enabled in if !enabled { isHovered = false } }
            .onDisappear { isHovered = false }
    }
}
