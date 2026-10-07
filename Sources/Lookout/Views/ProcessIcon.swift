import LookoutCore
import SwiftUI

struct ProcessIcon: View {
    let id: EnergyProcessID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "gearshape.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: ProcessIconCache.iconSize - 2, height: ProcessIconCache.iconSize - 2)
            }
        }
        .frame(width: ProcessIconCache.iconSize, height: ProcessIconCache.iconSize)
        .accessibilityHidden(true)
        .task(id: id) { image = ProcessIconCache.shared.image(for: id) }
    }
}
