import LookoutCore
import Combine
import ServiceManagement

/// The OS registration is the source of truth; a saved Boolean can become stale in System Settings.
@MainActor final class LoginItemService: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private let service = SMAppService.mainApp

    init() { status = SMAppService.mainApp.status }
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var statusMessage: String {
        switch status {
        case .notRegistered: L10n.text("자동 실행 꺼짐")
        case .enabled: L10n.text("로그인 시 자동 실행이 등록되었습니다.")
        case .requiresApproval: L10n.text("시스템 설정에서 Lookout의 자동 실행을 허용해주세요.")
        case .notFound: L10n.text("등록된 로그인 항목을 찾을 수 없습니다.")
        @unknown default: L10n.text("자동 실행 상태를 확인할 수 없습니다.")
        }
    }
    func refresh() {
        let latest = service.status
        if latest != status { status = latest }
    }
    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        refresh()
        guard enabled != isEnabled else { return }
        isChanging = true
        errorMessage = nil
        defer { refresh(); isChanging = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch {
            errorMessage = L10n.text("자동 실행 \(enabled ? L10n.text("등록") : L10n.text("해제")) 실패: \(error.localizedDescription)")
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
