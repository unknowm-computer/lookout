import AppKit
import LookoutCore

/// Launch the same bundle before terminating, so a launch failure leaves this app usable.
@MainActor struct AppRelauncher {
    private let applicationURL: URL
    private let synchronize: @MainActor () -> Bool
    private let openApplication: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> Int32
    private let terminate: @MainActor () -> Void

    init(applicationURL: URL = Bundle.main.bundleURL,
         synchronize: @escaping @MainActor () -> Bool = { UserDefaults.standard.synchronize() },
         openApplication: @escaping @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> Int32 = { url, configuration in
             try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
         },
         terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.applicationURL = applicationURL
        self.synchronize = synchronize
        self.openApplication = openApplication
        self.terminate = terminate
    }

    func restart() async throws {
        guard applicationURL.pathExtension.lowercased() == "app" else { throw RestartError.applicationLocation }
        guard synchronize() else { throw RestartError.settingsSave }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--settings"]
        configuration.activates = true
        let pid = try await openApplication(applicationURL, configuration)
        guard pid != ProcessInfo.processInfo.processIdentifier else { throw RestartError.sameInstance }
        terminate()
    }

    private enum RestartError: LocalizedError {
        case applicationLocation, settingsSave, sameInstance
        var errorDescription: String? {
            switch self {
            case .applicationLocation: L10n.text("앱의 위치를 확인할 수 없습니다. Lookout을 종료한 뒤 직접 다시 실행하세요.")
            case .settingsSave: L10n.text("언어 설정을 저장할 수 없습니다. 잠시 후 다시 시도하세요.")
            case .sameInstance: L10n.text("새 앱을 실행할 수 없습니다. Lookout을 종료한 뒤 직접 다시 실행하세요.")
            }
        }
    }
}
