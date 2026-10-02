import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: factor, y: factor)
        let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.21, alpha: 1).setFill()
        background.fill()
        for (index, height) in [250.0, 430.0, 330.0].enumerated() {
            NSColor(calibratedRed: 0.25, green: 0.86, blue: 0.78, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 225 + CGFloat(index) * 205, y: 250, width: 145, height: height),
                         xRadius: 42, yRadius: 42).fill()
        }
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 707, y: 713, width: 66, height: 66)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: output.appendingPathComponent(name))
    }
}
