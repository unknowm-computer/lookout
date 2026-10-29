import Combine
import FanControlProtocol
import Foundation
import LookoutCore
import ServiceManagement
import WindowHelperProtocol

@MainActor protocol FanHelperRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

enum HelperServiceKind {
    case fan, window
    var enabledKey: String { self == .fan ? "fanHelperEnabled.v1" : "windowHelperEnabled.v1" }
    var revisionKey: String { self == .fan ? "fanHelperRevision.v1" : "windowHelperRevision.v1" }
}

@MainActor private final class SystemFanHelperRegistration: FanHelperRegistering {
    private let service: SMAppService
    init(kind: HelperServiceKind) {
        service = kind == .fan ? .daemon(plistName: FanControlEndpoint.plist) : .agent(plistName: WindowHelperEndpoint.plist)
    }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

/// Reads OS state without changing registration. Only activate() performs a user-requested setup.
@MainActor final class FanHelperMaintenance: ObservableObject {
    static let enabledKey = "fanHelperEnabled.v1"
    static let revisionKey = "fanHelperRevision.v1"
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var updating = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let revision: String?
    private let kind: HelperServiceKind
    private let service: any FanHelperRegistering
    private let settle: @MainActor () async throws -> Void

    init(defaults: UserDefaults, revision: String?, kind: HelperServiceKind = .fan, service: (any FanHelperRegistering)? = nil,
         settle: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        self.defaults = defaults; self.revision = revision; self.kind = kind
        self.service = service ?? SystemFanHelperRegistration(kind: kind); self.settle = settle
    }
    var needsRefresh: Bool { status == .enabled && (revision == nil || defaults.string(forKey: kind.revisionKey) != revision) }
    func refresh() {
        let latest = service.status
        if status != latest { status = latest }
        if latest == .requiresApproval { error = nil }
    }
    /// Invoked only by the setup/update/retry button. OS approval remains a separate user action.
    func activate(force: Bool = false) {
        guard !updating else { return }
        refresh()
        guard status != .requiresApproval else { return }
        guard force || status != .enabled || needsRefresh || error != nil else { return }
        guard let revision else { error = kind == .fan ? L10n.text("팬 제어 앱 서명을 확인할 수 없습니다.") : L10n.text("창 배치 앱 서명을 확인할 수 없습니다."); return }
        defaults.set(true, forKey: kind.enabledKey)
        updating = true; error = nil
        Task {
            defer { updating = false }
            do {
                if service.status == .requiresApproval { refresh(); return }
                if service.status == .enabled {
                    try await service.unregister()
                    try await settle()
                }
                // A delayed OS consent change must not be replaced by another registration request.
                if service.status == .requiresApproval { refresh(); return }
                try service.register()
                try await settle()
                refresh()
                if status == .enabled || status == .requiresApproval {
                    defaults.set(revision, forKey: kind.revisionKey)
                } else {
                    error = kind == .fan ? L10n.text("팬 제어 서비스를 준비하지 못했습니다. 다시 시도해주세요.") : L10n.text("창 배치 도우미를 준비하지 못했습니다. 다시 시도해주세요.")
                }
            } catch {
                refresh()
                if status != .requiresApproval {
                    self.error = kind == .fan ? L10n.text("팬 제어 활성화 실패: \(error.localizedDescription)") : L10n.text("창 배치 설정 실패: \(error.localizedDescription)")
                }
            }
        }
    }
}
