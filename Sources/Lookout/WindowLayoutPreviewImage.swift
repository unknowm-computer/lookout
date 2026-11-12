import CoreGraphics
import ImageIO
import WindowHelperProtocol

enum WindowLayoutPreviewImage {
    static func make(_ preview: WindowLayoutPreview) -> CGImage? {
        let images = preview.images.compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard !images.isEmpty, images.count == preview.images.count else { return nil }
        if images.count == 1 { return images[0] }

        let frames: [CGRect]
        if let saved = preview.displayFrames, saved.count == images.count {
            frames = saved.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        } else {
            var x: CGFloat = 0
            frames = images.map { image in
                let width = CGFloat(image.width) / CGFloat(image.height)
                defer { x += width }
                return CGRect(x: x, y: 0, width: width, height: 1)
            }
        }
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(720 / bounds.width, 360 / bounds.height)
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        for (image, frame) in zip(images, frames) {
            // Saved display frames have a top-left origin. Core Graphics draws from the bottom left.
            let rect = CGRect(x: (frame.minX - bounds.minX) * scale, y: (bounds.maxY - frame.maxY) * scale,
                              width: frame.width * scale, height: frame.height * scale)
            canvas.draw(image, in: rect)
        }
        return canvas.makeImage()
    }
}
