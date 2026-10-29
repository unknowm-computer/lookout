import AppKit
import ApplicationServices
import ColorSync
import WindowLayoutModel

@MainActor protocol WindowLayoutBackend: AnyObject {
    var isTrusted: Bool { get }
    func checkPermission() -> WindowAccessReport
    func displays() -> [LayoutDisplay]
    func capture() -> WindowLayoutSnapshot?
    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay]) -> WindowRestoreResult
}

extension WindowLayoutBackend {
    func checkPermission() -> WindowAccessReport {
        WindowAccessReport(trustedAPI: isTrusted, query: .notChecked)
    }
}

struct WindowRestoreResult {
    var restored = 0
    var skipped = 0
    var failed: [LayoutWindow] = []
}

/// AX access stays on the main actor. Calls have a short per-process timeout and a total work budget.
@MainActor final class AccessibilityWindowLayoutBackend: WindowLayoutBackend {
    private var references: [UUID: AXUIElement] = [:]
    private var access: WindowAccessReport?
    var isTrusted: Bool { access?.canAccess ?? AXIsProcessTrusted() }
    func checkPermission() -> WindowAccessReport {
        let report = WindowAccessDiagnostics.check()
        access = report
        return report
    }

    func displays() -> [LayoutDisplay] {
        guard let top = NSScreen.screens.first?.frame.maxY else { return [] }
        let screens = NSScreen.screens
        let result = screens.compactMap { screen -> LayoutDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            func rect(_ frame: CGRect) -> LayoutRect {
                LayoutRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
            }
            return LayoutDisplay(id: id, frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame))
        }.sorted { $0.id < $1.id }
        return result.count == screens.count ? result : []
    }

    func capture() -> WindowLayoutSnapshot? {
        guard isTrusted else { return nil }
        let screens = displays(), deadline = ProcessInfo.processInfo.systemUptime + 2
        guard !screens.isEmpty else { return nil }
        var records: [LayoutWindow] = [], elements: [UUID: AXUIElement] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != "local.lookout.app" {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard let bundle = app.bundleIdentifier, let launch = WindowProcessIdentity.launchDate(for: app) else { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.12)
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
            if error == .cannotComplete { return nil } // Do not replace a good snapshot with a partial capture.
            guard error == .success, let windows = raw as? [AXUIElement] else { continue }
            for window in windows {
                guard ProcessInfo.processInfo.systemUptime < deadline, records.count < 200 else { return nil }
                AXUIElementSetMessagingTimeout(window, 0.12)
                guard eligible(window), let frame = frame(window),
                      let screen = screens.max(by: { $0.frame.intersectionArea(with: frame) < $1.frame.intersectionArea(with: frame) }),
                      screen.frame.intersectionArea(with: frame) > 0 else { continue }
                let record = LayoutWindow(bundleID: bundle, pid: app.processIdentifier, launchDate: launch,
                                          identifier: string(window, kAXIdentifierAttribute), title: string(window, kAXTitleAttribute),
                                          displayID: screen.id,
                                          frame: LayoutRect(x: frame.x - screen.frame.x, y: frame.y - screen.frame.y,
                                                            width: frame.width, height: frame.height))
                records.append(record); elements[record.id] = window
            }
        }
        guard displays() == screens else { return nil }
        let snapshot = WindowLayoutSnapshot(displays: screens, windows: records)
        guard snapshot.isValid else { return nil }
        // Retain the previous snapshot's handles as well, for safe same-session backup restoration.
        references.merge(elements) { _, new in new }
        if references.count > 400 { references = elements }
        return snapshot
    }

    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay]) -> WindowRestoreResult {
        var result = WindowRestoreResult()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var cached: [Int32: [AXUIElement]] = [:]
        var unavailable: Set<Int32> = []
        for record in windows {
            guard isTrusted, ProcessInfo.processInfo.systemUptime < deadline else { result.failed.append(record); continue }
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
                  app.bundleIdentifier == record.bundleID,
                  WindowProcessIdentity.launchDate(for: app) == record.launchDate else { result.skipped += 1; continue }
            if cached[record.pid] == nil && !unavailable.contains(record.pid) {
                let application = AXUIElementCreateApplication(record.pid)
                AXUIElementSetMessagingTimeout(application, 0.12)
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
                   let list = raw as? [AXUIElement] { cached[record.pid] = list }
                else { unavailable.insert(record.pid) }
            }
            guard let list = cached[record.pid] else { result.failed.append(record); continue }
            let element: AXUIElement?
            if let saved = references[record.id], list.contains(where: { CFEqual($0, saved) }) { element = saved }
            else {
                var matches: [AXUIElement] = []
                var expired = false
                for window in list {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { expired = true; break }
                    AXUIElementSetMessagingTimeout(window, 0.12)
                    let matchesIdentity = !record.identifier.isEmpty
                        ? string(window, kAXIdentifierAttribute) == record.identifier
                        : !record.title.isEmpty && string(window, kAXTitleAttribute) == record.title
                    if matchesIdentity { matches.append(window) }
                    if matches.count > 1 { break }
                }
                if expired || matches.count > 1 { result.failed.append(record); continue }
                element = matches.count == 1 ? matches[0] : nil
            }
            guard let element, eligible(element), let target = record.target(on: displays) else { result.skipped += 1; continue }
            // Do not activate apps, change Spaces, or unminimize/fullscreen windows.
            if apply(target, to: element) { result.restored += 1 }
            else { result.failed.append(record) }
        }
        return result
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { value(element, name) as? String ?? "" }
    private func eligible(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && (value(element, kAXMinimizedAttribute) as? Bool) == false
            && (value(element, "AXFullScreen") as? Bool) != true
            && settable(element, kAXPositionAttribute)
    }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
    }
    private func frame(_ element: AXUIElement) -> LayoutRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let rect = LayoutRect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
        return rect.isValid ? rect : nil
    }
    private func apply(_ rect: LayoutRect, to element: AXUIElement) -> Bool {
        var point = CGPoint(x: rect.x, y: rect.y), size = CGSize(width: rect.width, height: rect.height)
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        let resizable = settable(element, kAXSizeAttribute)
        if resizable {
            guard AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions) == .success else { return false }
        }
        guard AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success,
              let actual = frame(element) else { return false }
        // Some apps acknowledge writes but constrain the window. Verify the result.
        return abs(actual.x - rect.x) < 8 && abs(actual.y - rect.y) < 8
            && (!resizable || (abs(actual.width - rect.width) < 8 && abs(actual.height - rect.height) < 8))
    }
}
