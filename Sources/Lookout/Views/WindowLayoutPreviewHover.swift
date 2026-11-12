import SwiftUI

/// Load the saved image only while its label or restore action is hovered.
struct WindowLayoutPreviewHover: ViewModifier {
    @ObservedObject var service: WindowLayoutClient
    @Binding var hovering: Bool
    @State private var preview: (date: Date, image: CGImage)?

    private var requestedDate: Date? { hovering ? service.savedPreviewAt : nil }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .background {
                WindowLayoutPreviewTooltip(image: requestedDate == preview?.date ? preview?.image : nil)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: requestedDate) {
                preview = nil
                guard let date = requestedDate,
                      let saved = await service.loadPreview(previous: false, date: date),
                      !Task.isCancelled, requestedDate == date,
                      let image = WindowLayoutPreviewImage.make(saved) else { return }
                preview = (date, image)
            }
            .onDisappear { hovering = false; preview = nil }
    }
}
