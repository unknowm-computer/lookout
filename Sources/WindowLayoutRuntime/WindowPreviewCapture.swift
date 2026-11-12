import ColorSync
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
import WindowLayoutModel

enum WindowPreviewCapture {
    static func start(displays: [LayoutDisplay]) -> Task<[Data], Never> {
        let started = ContinuousClock.now
        let awakeStarted = SuspendingClock.now
        return Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  ContinuousClock.now - started < .seconds(3),
                  let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
            let excludedApps = content.applications.filter { $0.bundleIdentifier == "local.lookout.app" }
            let displayIDs = Set(displays.map(\.id))
            let sources = content.displays.compactMap { display -> (String, SCDisplay)? in
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue() else { return nil }
                let id = CFUUIDCreateString(nil, uuid) as String
                return displayIDs.contains(id) ? (id, display) : nil
            }.sorted { $0.0 < $1.0 }
            guard sources.count == displays.count else { return [] }
            var images: [Data] = []
            for (_, display) in sources {
                guard !Task.isCancelled, ContinuousClock.now - started < .seconds(3) else { return [] }
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                let width = max(display.width, 1), height = max(display.height, 1)
                let scale = min(1, 768.0 / Double(max(width, height)))
                configuration.width = max(1, Int(Double(width) * scale))
                configuration.height = max(1, Int(Double(height) * scale))
                configuration.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                      let data = jpeg(image) else { return [] }
                images.append(data)
            }
            let elapsed = ContinuousClock.now - started
            guard !Task.isCancelled, elapsed < .seconds(3),
                  elapsed - (SuspendingClock.now - awakeStarted) < .milliseconds(100) else { return [] }
            return images
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 180_000 else { return nil }
        return output as Data
    }
}
