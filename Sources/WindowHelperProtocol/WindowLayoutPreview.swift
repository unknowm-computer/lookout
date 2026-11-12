import Foundation
import ImageIO
import WindowLayoutModel

public struct WindowLayoutPreview: Codable, Sendable {
    public let date: Date
    public let images: [Data]
    public let displayFrames: [LayoutRect]?
    public init(date: Date, images: [Data], displayFrames: [LayoutRect]? = nil) {
        self.date = date
        self.images = images
        self.displayFrames = displayFrames
    }

    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= WindowHelperEndpoint.maximumTransferBytes,
              let preview = try? JSONDecoder().decode(Self.self, from: data),
              (1...16).contains(preview.images.count),
              preview.displayFrames.map({ $0.count == preview.images.count && $0.allSatisfy(\.isValid) }) != false,
              preview.images.allSatisfy({ isValidJPEG($0) }) else {
            return nil
        }
        return preview
    }

    private static func isValidJPEG(_ data: Data) -> Bool {
        guard (4...180_000).contains(data.count), data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...768).contains(width) && (1...768).contains(height)
    }
}
