import AppKit
import ApplicationServices
import WindowLayoutModel

/// Uses read-only AX window-list requests; unresponsive or unsupported apps are not treated as denial.
@MainActor public enum WindowAccessDiagnostics {
    public static func check() -> WindowAccessReport {
        let trusted = AXIsProcessTrusted()
        var apps: [NSRunningApplication] = []
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { apps.append(front) }
        apps += NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        var checked: Set<pid_t> = [], last: AXError?
        var denied = false
        for app in apps where !app.isTerminated && checked.insert(app.processIdentifier).inserted {
            let target = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(target, 0.15)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(target, kAXWindowsAttribute as CFString, &result)
            if error == .success, result as? [AXUIElement] != nil {
                return WindowAccessReport(trustedAPI: trusted, query: .allowed)
            }
            if error == .apiDisabled { denied = true }
            last = error
        }
        return WindowAccessReport(trustedAPI: trusted, query: denied ? .denied : .unavailable, errorCode: last?.rawValue)
    }
}
