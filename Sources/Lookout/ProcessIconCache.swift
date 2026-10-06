import AppKit
import Darwin
import LookoutCore

/// Only queried by visible process rows. PID plus start time prevents reuse of an old process's icon.
@MainActor final class ProcessIconCache {
    static let shared = ProcessIconCache()
    static let iconSize: CGFloat = 14
    private struct Entry { let image: NSImage? }
    private var processes: [EnergyProcessID: Entry] = [:]
    private var insertionOrder: [EnergyProcessID] = []
    private let appIcons = NSCache<NSURL, NSImage>()
    private let capacity: Int
    private let appURL: @MainActor (EnergyProcessID) -> URL?
    private let loadIcon: @MainActor (URL) -> NSImage?

    init(capacity: Int = 128,
         appURL: @escaping @MainActor (EnergyProcessID) -> URL? = ProcessIconCache.applicationURL,
         loadIcon: @escaping @MainActor (URL) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0.path) }) {
        self.capacity = max(1, capacity)
        self.appURL = appURL
        self.loadIcon = loadIcon
        appIcons.countLimit = 64
    }

    func image(for id: EnergyProcessID) -> NSImage? {
        if let entry = processes[id] { return entry.image }
        var image: NSImage?
        if let url = appURL(id) {
            image = appIcons.object(forKey: url as NSURL)
            if image == nil, let source = loadIcon(url) {
                image = Self.thumbnail(source)
                if let image { appIcons.setObject(image, forKey: url as NSURL) }
            }
        }
        if insertionOrder.count >= capacity {
            processes.removeValue(forKey: insertionOrder.removeFirst())
        }
        // A missing icon is cached too, so daemons are not looked up every sampling interval.
        processes[id] = Entry(image: image)
        insertionOrder.append(id)
        return image
    }

    private static func applicationURL(_ id: EnergyProcessID) -> URL? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(id.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0, info.ri_proc_start_abstime == id.started else { return nil }
        if let url = NSRunningApplication(processIdentifier: id.pid)?.bundleURL {
            return enclosingApplication(url) ?? url
        }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift (4 * MAXPATHLEN).
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(id.pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let executable = String(decoding: path.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return enclosingApplication(URL(fileURLWithPath: executable))
    }

    /// Prefer the containing app over nested helper .app bundles; do not search unrelated parent processes.
    static func enclosingApplication(_ url: URL) -> URL? {
        var current = url.standardizedFileURL
        var result: URL?
        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" { result = current }
            current.deleteLastPathComponent()
        }
        return result
    }

    private static func thumbnail(_ source: NSImage) -> NSImage? {
        let pixels = Int(iconSize * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                    operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
