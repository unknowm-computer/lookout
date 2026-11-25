import AppKit
import ApplicationServices
import ColorSync
import CryptoKit
import Darwin
import WindowLayoutModel

@MainActor protocol WindowLayoutBackend: AnyObject {
    var isTrusted: Bool { get }
    var captureDisplaysAwake: Bool { get }
    var isScreenLocked: Bool { get }
    var areScreensAsleep: Bool { get }
    func checkPermission() -> WindowAccessReport
    func displays() -> [LayoutDisplay]
    func capture(timeBudget: TimeInterval) -> WindowLayoutSnapshot?
    func retainReferences(for windows: Set<UUID>)
    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay], identityScope: [LayoutWindow]) -> WindowRestoreResult
}

extension WindowLayoutBackend {
    var isScreenLocked: Bool { false }
    var areScreensAsleep: Bool { false }

    func checkPermission() -> WindowAccessReport {
        WindowAccessReport(trustedAPI: isTrusted, query: .notChecked)
    }
    func retainReferences(for windows: Set<UUID>) {}
}

struct WindowRestoreResult {
    var restored = 0
    var skipped = 0
    var failed: [LayoutWindow] = []
    var issues: [WindowRestoreIssue] = []
    mutating func fail(_ record: LayoutWindow, reason: WindowRestoreFailure, code: Int32? = nil, app: String? = nil) {
        failed.append(record)
        issues.append(WindowRestoreIssue(id: record.id, app: app ?? record.bundleID, title: record.title,
                                         reason: reason, errorCode: code))
    }
    var report: WindowRestoreReport {
        WindowRestoreReport(restored: restored, skipped: skipped, failed: failed.count, issues: issues)
    }
}

/// AX access stays on the main actor. Calls have a short per-process timeout and a total work budget.
@MainActor final class AccessibilityWindowLayoutBackend: WindowLayoutBackend {
    private var references: [UUID: AXUIElement] = [:]
    private var access: WindowAccessReport?
    var isTrusted: Bool { access?.canAccess ?? AXIsProcessTrusted() }
    var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
    var areScreensAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    var captureDisplaysAwake: Bool {
        NSScreen.screens.allSatisfy { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let display = number.uint32Value
            return CGDisplayIsAsleep(display) == 0
        }
    }
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

    func capture(timeBudget: TimeInterval) -> WindowLayoutSnapshot? {
        guard isTrusted else { return nil }
        let screens = displays()
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        guard !screens.isEmpty else { return nil }
        var records: [LayoutWindow] = [], elements: [UUID: AXUIElement] = [:]
        var incompleteDocuments = Set<String>()
        var isPartial = false
        apps: for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != "local.lookout.app" {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                isPartial = true
                break
            }
            guard let bundle = app.bundleIdentifier, let launch = WindowProcessIdentity.launchDate(for: app) else { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.12)
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
            if error == .apiDisabled { return nil }
            if error == .cannotComplete {
                // AppKit can still list a process that has already exited.
                // Only a process that might have windows can make this capture incomplete.
                guard !app.isTerminated else { continue }
                if kill(app.processIdentifier, 0) == -1, errno == ESRCH { continue }
                isPartial = true
                continue
            }
            guard error == .success, let windows = raw as? [AXUIElement] else { continue }
            for window in windows {
                guard ProcessInfo.processInfo.systemUptime < deadline, records.count < 200 else {
                    isPartial = true
                    break apps
                }
                AXUIElementSetMessagingTimeout(window, 0.12)
                guard eligible(window), let frame = frame(window),
                      let screen = screens.max(by: { $0.frame.intersectionArea(with: frame) < $1.frame.intersectionArea(with: frame) }),
                      screen.frame.intersectionArea(with: frame) > 0 else { continue }
                let reading = readIdentity(window)
                let identity = reading.identity
                if reading.documentError != nil { incompleteDocuments.insert(bundle) }
                let record = LayoutWindow(bundleID: bundle, pid: app.processIdentifier, launchDate: launch,
                                          identifier: identity.identifier, title: identity.title, displayID: screen.id,
                                          frame: LayoutRect(x: frame.x - screen.frame.x, y: frame.y - screen.frame.y,
                                                            width: frame.width, height: frame.height),
                                          documentDigest: identity.documentDigest)
                records.append(record); elements[record.id] = window
            }
        }
        guard LayoutDisplay.sameTopology(screens, displays()) else { return nil }
        for index in records.indices where incompleteDocuments.contains(records[index].bundleID) {
            records[index].documentDigest = nil
        }
        let snapshot = WindowLayoutSnapshot(displays: screens, windows: records, savedWithOmissions: isPartial ? true : nil)
        guard snapshot.isValid else { return nil }
        references.merge(elements) { _, new in new }
        return snapshot
    }

    func retainReferences(for windows: Set<UUID>) {
        references = references.filter { windows.contains($0.key) }
    }

    func restore(_ windows: [LayoutWindow], displays: [LayoutDisplay], identityScope: [LayoutWindow]) -> WindowRestoreResult {
        var result = WindowRestoreResult()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let requests = Dictionary(grouping: windows, by: \.bundleID)
        let scopes = Dictionary(grouping: identityScope, by: \.bundleID)
        var handled = Set<String>()
        for record in windows where handled.insert(record.bundleID).inserted {
            guard let requested = requests[record.bundleID] else { continue }
            guard isTrusted else {
                for window in requested { result.fail(window, reason: .permissionDenied) }
                continue
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                for window in requested { result.fail(window, reason: .timeBudget) }
                continue
            }
            let scope = scopes[record.bundleID] ?? requested
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleID)
                .filter { !$0.isTerminated }
            var remaining = requested.count
            // A different process is eligible only when the bundle has exactly one running instance.
            let allowRestartedApp = apps.count == 1 && apps[0].activationPolicy == .regular
            for app in apps {
                guard let launchDate = WindowProcessIdentity.launchDate(for: app) else { continue }
                let pid = app.processIdentifier
                let targets = requested.filter {
                    ($0.pid == pid && $0.launchDate == launchDate) || (allowRestartedApp && $0.documentDigest != nil)
                }
                guard !targets.isEmpty else { continue }
                remaining -= targets.count
                restore(targets, for: app, launchDate: launchDate, scope: scope,
                        allowRestartedApp: allowRestartedApp, displays: displays, deadline: deadline, result: &result)
            }
            result.skipped += remaining
        }
        return result
    }

    private func restore(_ targets: [LayoutWindow], for app: NSRunningApplication, launchDate: Date,
                         scope: [LayoutWindow], allowRestartedApp: Bool, displays: [LayoutDisplay],
                         deadline: TimeInterval, result: inout WindowRestoreResult) {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            for record in targets { result.fail(record, reason: .timeBudget) }
            return
        }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let windows = raw as? [AXUIElement] else {
            let reason: WindowRestoreFailure = error == .apiDisabled ? .permissionDenied : .appUnresponsive
            for record in targets { result.fail(record, reason: reason, code: error.rawValue, app: app.localizedName) }
            return
        }

        let referenced = Dictionary(uniqueKeysWithValues: scope.compactMap { record -> (UUID, Int)? in
            guard let saved = references[record.id],
                  let index = windows.firstIndex(where: { CFEqual($0, saved) }) else { return nil }
            return (record.id, index)
        })
        var identities: [WindowIdentity] = []
        var metadataFailure: WindowRestoreFailure?
        var metadataError: AXError?
        var documentError: AXError?
        if !targets.allSatisfy({ $0.pid == pid && $0.launchDate == launchDate && referenced[$0.id] != nil }) {
            for window in windows {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    metadataFailure = .timeBudget
                    break
                }
                AXUIElementSetMessagingTimeout(window, 0.12)
                let reading = readIdentity(window)
                if let error = reading.error {
                    metadataFailure = error == .apiDisabled ? .permissionDenied : .appUnresponsive
                    metadataError = error
                    break
                }
                identities.append(reading.identity)
                documentError = documentError ?? reading.documentError
            }
        }
        // Incomplete metadata cannot establish that a match is unique.
        let matches = WindowIdentityMatcher.match(scope: scope, candidates: metadataFailure == nil ? identities : [],
            referenced: referenced, attempting: Set(targets.map(\.id)), pid: pid, launchDate: launchDate,
            allowRestartedApp: allowRestartedApp,
            documentsComplete: documentError == nil)
        for record in targets {
            guard isTrusted else { result.fail(record, reason: .permissionDenied); continue }
            guard ProcessInfo.processInfo.systemUptime < deadline else { result.fail(record, reason: .timeBudget); continue }
            if windows.isEmpty && record.pid == pid && record.launchDate == launchDate {
                result.skipped += 1
                continue
            }
            switch matches[record.id] ?? .missing {
            case .missing:
                let lookupError = metadataError ?? (record.documentDigest == nil ? nil : documentError)
                let reason: WindowRestoreFailure
                if let metadataFailure { reason = metadataFailure }
                else if lookupError == .apiDisabled { reason = .permissionDenied }
                else { reason = lookupError == nil ? .windowNotFound : .appUnresponsive }
                result.fail(record, reason: reason, code: lookupError?.rawValue, app: app.localizedName)
            case .ambiguous:
                result.fail(record, reason: .ambiguousIdentity, app: app.localizedName)
            case .found(let index):
                let element = windows[index]
                AXUIElementSetMessagingTimeout(element, 0.12)
                guard eligible(element), let target = record.target(on: displays) else { result.skipped += 1; continue }
                // Do not activate apps, change Spaces, or unminimize/fullscreen windows.
                if let failure = apply(target, to: element) {
                    result.fail(record, reason: failure.0, code: failure.1, app: app.localizedName)
                } else {
                    result.restored += 1
                    references[record.id] = element
                }
            }
        }
    }

    private func readIdentity(_ window: AXUIElement) -> (identity: WindowIdentity, error: AXError?, documentError: AXError?) {
        let attributes = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDocumentAttribute]
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(window, attributes as CFArray, [], &raw)
        guard error == .success, let values = raw as? [AnyObject], values.count == attributes.count else {
            // Keep the original identity lookup for apps that do not handle batched attributes.
            let identifier = readAttribute(window, kAXIdentifierAttribute)
            let title = readAttribute(window, kAXTitleAttribute)
            let document = readAttribute(window, kAXDocumentAttribute)
            return (WindowIdentity(identifier: identifier.value, title: title.value, documentDigest: documentDigest(document.value)),
                    identifier.error ?? title.error, document.error)
        }
        func attributeError(_ value: AnyObject) -> AXError? {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var failure = AXError.success
            if AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .axError, &failure),
               ![.success, .attributeUnsupported, .noValue].contains(failure) {
                return failure
            }
            return nil
        }
        return (WindowIdentity(identifier: values[0] as? String ?? "", title: values[1] as? String ?? "",
                               documentDigest: documentDigest(values[2] as? String ?? "")),
                attributeError(values[0]) ?? attributeError(values[1]), attributeError(values[2]))
    }

    private func readAttribute(_ window: AXUIElement, _ attribute: String) -> (value: String, error: AXError?) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &raw)
        return (raw as? String ?? "", [.success, .attributeUnsupported, .noValue].contains(error) ? nil : error)
    }

    private func documentDigest(_ address: String) -> Data? {
        guard address.utf8.count <= 16_384, let url = URL(string: address), url.scheme != nil else { return nil }
        // Paths can reveal document names. Retain only a digest for equality checks.
        return Data(SHA256.hash(data: Data(url.absoluteString.utf8)))
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
    private func apply(_ rect: LayoutRect, to element: AXUIElement) -> (WindowRestoreFailure, Int32?)? {
        var point = CGPoint(x: rect.x, y: rect.y), size = CGSize(width: rect.width, height: rect.height)
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return (.writeFailed, nil) }
        let resizable = settable(element, kAXSizeAttribute)
        if resizable {
            let error = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
            guard error == .success else { return (error == .apiDisabled ? .permissionDenied : .writeFailed, error.rawValue) }
        }
        let error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        guard error == .success else { return (error == .apiDisabled ? .permissionDenied : .writeFailed, error.rawValue) }
        guard let actual = frame(element) else { return (.verificationFailed, nil) }
        // Some apps acknowledge writes but constrain the window. Verify the result.
        let matches = abs(actual.x - rect.x) < 8 && abs(actual.y - rect.y) < 8
            && (!resizable || (abs(actual.width - rect.width) < 8 && abs(actual.height - rect.height) < 8))
        return matches ? nil : (.verificationFailed, nil)
    }
}
