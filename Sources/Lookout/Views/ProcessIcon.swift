import LookoutCore
import SwiftUI

struct ProcessIcon: View {
    let id: EnergyProcessID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: ProcessIconCache.iconSize, height: ProcessIconCache.iconSize)
        .accessibilityHidden(true)
        .task(id: id) { image = ProcessIconCache.shared.image(for: id) }
    }
}
