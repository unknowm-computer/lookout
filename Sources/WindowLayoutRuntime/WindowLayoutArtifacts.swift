import Foundation
import WindowHelperProtocol
import WindowLayoutModel

struct WindowLayoutLogEvent: Codable {
    struct Display: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ display: LayoutDisplay) {
            let frame = display.frame
            x = frame.x; y = frame.y; width = frame.width; height = frame.height
        }
    }

    struct Issue: Codable {
        let app: String
        let reason: WindowRestoreFailure
        let errorCode: Int32?
    }

    let date: Date
    let action: String
    let result: String
    var layoutDate: Date?
    var windows: Int?
    var expectedDisplays: [Display]?
    var displays: [Display]?
    var restored: Int?
    var skipped: Int?
    var failed: Int?
    var issues: [Issue]?

    init(_ action: String, _ result: String, layout: WindowLayoutSnapshot? = nil,
         displays: [LayoutDisplay]? = nil, report: WindowRestoreReport? = nil) {
        date = Date()
        self.action = action; self.result = result
        layoutDate = layout?.date; windows = layout?.windows.count
        expectedDisplays = layout?.displays.map(Display.init)
        self.displays = displays.map { Array($0.prefix(16)).map(Display.init) }
        restored = report?.restored; skipped = report?.skipped; failed = report?.failed
        issues = report?.issues.map { Issue(app: $0.app, reason: $0.reason, errorCode: $0.errorCode) }
    }
}

@MainActor final class WindowLayoutArtifacts {
    private struct Log: Codable {
        var schemaVersion = 1
        var macOS = ProcessInfo.processInfo.operatingSystemVersionString
        var events: [WindowLayoutLogEvent] = []
    }

    private let directory: URL
    private var log: Log?

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Lookout/Window Layout", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var logURL: URL { directory.appending(path: "diagnostics.json") }
    private func previewURL(_ date: Date) -> URL {
        directory.appending(path: "preview-\(date.timeIntervalSinceReferenceDate.bitPattern).json")
    }

    func record(_ event: WindowLayoutLogEvent) {
        var history = loadLog()
        history.events = Array((history.events + [event]).suffix(100))
        log = history
        if let data = encodeLog(history) { try? write(data, to: logURL) }
    }

    func diagnostics() -> Data? { encodeLog(loadLog()) }

    func store(_ preview: WindowLayoutPreview) -> Bool {
        guard let data = try? JSONEncoder().encode(preview), WindowLayoutPreview.decode(data) != nil else { return false }
        do { try write(data, to: previewURL(preview.date)); return true }
        catch { return false }
    }

    func preview(at date: Date?) -> Data? {
        guard let date else { return nil }
        return read(previewURL(date), limit: WindowHelperEndpoint.maximumTransferBytes)
    }

    func hasPreview(at date: Date?) -> Bool {
        guard let date else { return false }
        return FileManager.default.fileExists(atPath: previewURL(date).path)
    }

    func retainPreviews(for dates: [Date]) {
        let names = Set(dates.map { previewURL($0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("preview-") && file.pathExtension == "json"
            && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func loadLog() -> Log {
        if let log { return log }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = read(logURL, limit: WindowHelperEndpoint.maximumTransferBytes),
              let value = try? decoder.decode(Log.self, from: data), value.schemaVersion == 1 else { return Log() }
        return value
    }

    private func encodeLog(_ log: Log) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log), data.count <= WindowHelperEndpoint.maximumTransferBytes else { return nil }
        return data
    }

    private func read(_ url: URL, limit: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url), data.count <= limit else { return nil }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }
}
