import Foundation

public struct LayoutRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) < 100_000 }
            && width > 0 && height > 0
    }
    public func intersectionArea(with other: Self) -> Double {
        max(0, min(x + width, other.x + other.width) - max(x, other.x))
            * max(0, min(y + height, other.y + other.height) - max(y, other.y))
    }
    public func fitted(to visible: Self) -> Self {
        let w = min(width, visible.width), h = min(height, visible.height)
        return Self(x: min(max(x, visible.x), visible.x + visible.width - w),
                    y: min(max(y, visible.y), visible.y + visible.height - h), width: w, height: h)
    }
}

public struct LayoutDisplay: Codable, Equatable, Sendable {
    public var id: String
    public var frame: LayoutRect
    public var visibleFrame: LayoutRect
    public init(id: String, frame: LayoutRect, visibleFrame: LayoutRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
    public static func matches(_ saved: [Self], _ current: [Self]) -> Bool {
        guard !saved.isEmpty, saved.count == current.count,
              Set(saved.map(\.id)).count == saved.count,
              Set(current.map(\.id)).count == current.count else { return false }
        return saved.allSatisfy { display in
            current.contains { $0.id == display.id && abs($0.frame.width - display.frame.width) < 1
                && abs($0.frame.height - display.frame.height) < 1 }
        }
    }
}

public struct LayoutWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var pid: Int32
    public var launchDate: Date
    public var identifier: String
    public var title: String
    public var displayID: String
    /// Position relative to the saved display, in Accessibility's top-left coordinates.
    public var frame: LayoutRect
    public init(id: UUID = UUID(), bundleID: String, pid: Int32, launchDate: Date,
                identifier: String, title: String, displayID: String, frame: LayoutRect) {
        self.id = id; self.bundleID = bundleID; self.pid = pid; self.launchDate = launchDate
        self.identifier = identifier; self.title = title; self.displayID = displayID; self.frame = frame
    }
    public func target(on displays: [LayoutDisplay]) -> LayoutRect? {
        guard let display = displays.first(where: { $0.id == displayID }) else { return nil }
        return LayoutRect(x: display.frame.x + frame.x, y: display.frame.y + frame.y,
                          width: frame.width, height: frame.height).fitted(to: display.visibleFrame)
    }
}

public struct WindowLayoutSnapshot: Codable, Equatable, Sendable {
    public var date: Date
    public var displays: [LayoutDisplay]
    public var windows: [LayoutWindow]
    public init(date: Date = Date(), displays: [LayoutDisplay], windows: [LayoutWindow]) {
        self.date = date; self.displays = displays; self.windows = windows
    }
    public var isValid: Bool {
        !displays.isEmpty && displays.count <= 16 && !windows.isEmpty && windows.count <= 200
            && date.timeIntervalSince1970.isFinite
            && Set(displays.map(\.id)).count == displays.count
            && displays.allSatisfy { !$0.id.isEmpty && $0.id.count <= 256 && $0.frame.isValid && $0.visibleFrame.isValid }
            && Set(windows.map(\.id)).count == windows.count
            && windows.allSatisfy { window in
                window.pid > 0 && !window.bundleID.isEmpty && window.bundleID.count <= 512
                    && window.launchDate.timeIntervalSince1970.isFinite
                    && window.identifier.count <= 4096 && window.title.count <= 4096
                    && window.frame.isValid && displays.contains { $0.id == window.displayID }
            }
    }
    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}
