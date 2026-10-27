import Combine
import FanControlProtocol
import Foundation
import LookoutCore
import ServiceManagement

@MainActor protocol FanHelperRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor private final class SystemFanHelperRegistration: FanHelperRegistering {
    private let service = SMAppService.daemon(plistName: FanControlEndpoint.plist)
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

/// Event-driven registration maintenance. Never enrolls a new user or changes OS consent.
@MainActor final class FanHelperMaintenance: ObservableObject {
    static let enabledKey = "fanHelperEnabled.v1"
    static let revisionKey = "fanHelperRevision.v1"
    private static let approvalKey = "fanHelperApprovalPending.v1"
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var updating = false
    @Published private(set) var error: String?
    var onReady: (() -> Void)?
    private let defaults: UserDefaults
    private let revision: String?
    private let service: any FanHelperRegistering
    private let settle: @MainActor () async throws -> Void
    private var attempts: Set<String> = []

    init(defaults: UserDefaults, revision: String?, service: (any FanHelperRegistering)? = nil,
         settle: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        self.defaults = defaults; self.revision = revision
        self.service = service ?? SystemFanHelperRegistration(); self.settle = settle
    }
    var previouslyEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey) || defaults.string(forKey: Self.revisionKey) != nil
            || status == .enabled || status == .requiresApproval
    }
    var needsRefresh: Bool { status == .enabled && (revision == nil || defaults.string(forKey: Self.revisionKey) != revision) }
    func refresh() {
        let latest = service.status
        if status != latest { status = latest }
        if previouslyEnabled { defaults.set(true, forKey: Self.enabledKey) }
        if latest == .requiresApproval { defaults.set(true, forKey: Self.approvalKey) }
    }
    /// Called on launch, settings appearance, app activation and wake, never by a polling timer.
    func checkForUpdate() {
        refresh()
        guard previouslyEnabled, !updating else { return }
        // Respect a disabled background switch. Only macOS/the user can approve it.
        guard status != .requiresApproval else { error = nil; return }
        if defaults.bool(forKey: Self.approvalKey), status == .enabled {
            if begin(phase: "approval") { return }
            // Approval is now enabled; a second update is not repeated indefinitely.
            defaults.set(false, forKey: Self.approvalKey)
            onReady?()
        } else if needsRefresh || status == .notRegistered || status == .notFound {
            _ = begin(phase: "update")
        }
    }
    func activate() {
        guard !updating else { return }
        defaults.set(true, forKey: Self.enabledKey)
        attempts.removeAll()
        refresh()
        guard status != .requiresApproval else { error = nil; return }
        _ = begin(phase: "manual")
    }
    /// One recovery pass per launch if launchd still has an obsolete executable identity.
    @discardableResult func repairOnce() -> Bool {
        refresh()
        guard previouslyEnabled, !updating, status != .requiresApproval else { return false }
        let started = begin(phase: "repair")
        if !started { error = L10n.text("팬 제어 서비스를 준비하지 못했습니다. 다시 시도해주세요.") }
        return started
    }
    @discardableResult private func begin(phase: String) -> Bool {
        guard !updating else { return false }
        guard let revision else { error = L10n.text("팬 제어 앱 서명을 확인할 수 없습니다."); return false }
        guard attempts.insert("\(revision)|\(phase)").inserted else { return false }
        updating = true; error = nil
        Task {
            defer { updating = false }
            do {
                if service.status == .enabled || service.status == .requiresApproval {
                    try await service.unregister()
                    try await settle()
                }
                try service.register()
                // Allow ServiceManagement's asynchronous authorization state to settle once.
                try await settle()
                refresh()
                defaults.set(revision, forKey: Self.revisionKey)
                if status == .enabled {
                    defaults.set(false, forKey: Self.approvalKey)
                    // Finish before asking the owner to resume a saved cooling mode.
                    updating = false; onReady?()
                } else if status != .requiresApproval {
                    error = L10n.text("팬 제어 서비스를 준비하지 못했습니다. 다시 시도해주세요.")
                }
            } catch {
                try? await settle()
                refresh()
                if status != .requiresApproval {
                    self.error = L10n.text("팬 제어 활성화 실패: \(error.localizedDescription)")
                }
            }
        }
        return true
    }
}
