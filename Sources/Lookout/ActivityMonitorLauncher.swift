import AppKit

@MainActor enum ActivityMonitorLauncher {
    static func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            throw LaunchError.notFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Reuse the existing application instance when Activity Monitor is already running.
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    private enum LaunchError: LocalizedError {
        case notFound
        var errorDescription: String? { "활성 상태 보기 앱을 찾을 수 없습니다." }
    }
}
