import AppKit
import Foundation
import Testing
import WindowHelperProtocol
import WindowLayoutModel
@testable import Lookout
@testable import WindowLayoutRuntime

@Test @MainActor func windowDiagnosticsPersistBoundedHistoryWithoutWindowTitlesOrImages() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts = WindowLayoutArtifacts(directory: directory)
    artifacts.record(WindowLayoutLogEvent("automaticSave", "first"))
    for _ in 0..<99 { artifacts.record(WindowLayoutLogEvent("automaticSave", "saved")) }
    let issue = WindowRestoreIssue(id: UUID(), app: "Finder", title: "private window title", reason: .ambiguousIdentity)
    let report = WindowRestoreReport(restored: 1, skipped: 2, failed: 1, issues: [issue])
    artifacts.record(WindowLayoutLogEvent("automaticRestore", "incomplete", report: report))

    let persisted = WindowLayoutArtifacts(directory: directory)
    let data = try #require(persisted.diagnostics())
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let events = try #require(root["events"] as? [[String: Any]])
    #expect(events.count == 100 && events.first?["result"] as? String == "saved")
    #expect(events.last?["result"] as? String == "incomplete" && events.last?["failed"] as? Int == 1)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("Finder") && json.contains("ambiguousIdentity"))
    #expect(!json.contains("private window title") && !json.contains(issue.id.uuidString))
}

@Test @MainActor func windowPreviewsStayPairedWithTheirSavedDatesAndCanBeRemoved() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifacts = WindowLayoutArtifacts(directory: directory)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(.red, atX: 0, y: 0)
    let image = try #require(bitmap.representation(using: .jpeg, properties: [:]))
    let old = Date(timeIntervalSinceReferenceDate: 10), current = old.addingTimeInterval(0.5)
    #expect(artifacts.store(WindowLayoutPreview(date: old, images: [image])))
    #expect(artifacts.store(WindowLayoutPreview(date: current, images: [image, image])))
    #expect(!artifacts.store(WindowLayoutPreview(date: current, images: [Data([0xff, 0xd8, 0xff, 0x00])])))
    #expect(WindowLayoutPreview.decode(artifacts.preview(at: current))?.images == [image, image])
    #expect(WindowLayoutPreview.decode(artifacts.preview(at: old))?.date == old)
    artifacts.retainPreviews(for: [current])
    #expect(artifacts.preview(at: old) == nil && artifacts.hasPreview(at: current))
    artifacts.retainPreviews(for: [])
    #expect(!artifacts.hasPreview(at: current))
}

@Test @MainActor func windowPreviewCombinesSavedMonitorPositionsIntoOneImage() throws {
    func jpeg(red: CGFloat, blue: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]))
    }

    let images = [try jpeg(red: 1, blue: 0), try jpeg(red: 0, blue: 1)]
    let frames = [LayoutRect(x: -100, y: 0, width: 100, height: 100), LayoutRect(x: 0, y: -100, width: 100, height: 100)]
    let preview = WindowLayoutPreview(date: Date(), images: images, displayFrames: frames)
    let encoded = try JSONEncoder().encode(preview)
    let decoded = try #require(WindowLayoutPreview.decode(encoded))
    let image = try #require(WindowLayoutPreviewImage.make(decoded))
    let bitmap = NSBitmapImageRep(cgImage: image)
    #expect(image.width == 360 && image.height == 360)
    #expect(bitmap.colorAt(x: 90, y: 270)?.redComponent ?? 0 > 0.9)
    #expect(bitmap.colorAt(x: 270, y: 90)?.blueComponent ?? 0 > 0.9)
    #expect(bitmap.colorAt(x: 90, y: 90)?.alphaComponent == 0)
    #expect(bitmap.colorAt(x: 270, y: 270)?.alphaComponent == 0)

    let legacy = WindowLayoutPreview(date: preview.date, images: images)
    let fallback = try #require(WindowLayoutPreviewImage.make(legacy))
    #expect(fallback.width == 720 && fallback.height == 360)
}
