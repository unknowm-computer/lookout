import LookoutCore
import SwiftUI
import ServiceManagement

struct WindowLayoutSettingsView: View {
    @ObservedObject var service: WindowLayoutClient
    @State private var confirmsCurrentLayout = false
    @Environment(\.appearsActive) private var appearsActive
    private var needsPermissionCheck: Bool {
        !service.trusted || service.state?.permission.query != .allowed
    }
    private var needsRecovery: Bool {
        service.registration != .enabled || service.needsRefresh || service.connectionError != nil
            || service.maintenance.error != nil || !service.connected || needsPermissionCheck
    }
    private var recovering: Bool { service.connecting || service.maintenance.updating }
    private var recoveryMessage: String {
        if recovering { return L10n.text("설정을 복구하고 연결을 확인하는 중입니다.") }
        if service.registration == .requiresApproval { return L10n.text("창 배치 도우미의 백그라운드 실행을 허용해주세요.") }
        if let error = service.maintenance.error ?? service.connectionError { return error }
        if service.needsRefresh || service.registration != .enabled { return L10n.text("창 배치 도우미 등록·연결 설정이 필요합니다.") }
        if service.connected && needsPermissionCheck { return service.state?.permission.message ?? "" }
        return L10n.text("창 배치 도우미 연결됨")
    }
    private var helperStatus: some View {
        HelperRecoveryRow(message: recoveryMessage, working: recovering,
            needsApproval: service.registration == .requiresApproval,
            showsAction: needsRecovery, disabled: service.busy, recover: { service.install() }, openSettings: { service.openSystemSettings() })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("창 배치 자동 복원"))
            Toggle(L10n.text("잠자기 전 저장·복귀 후 자동 복원"), isOn: Binding(
                get: { service.enabled }, set: { service.setEnabled($0) }
            )).toggleStyle(.checkbox)
            Text(L10n.text("일반 창의 위치·크기를 자동 저장합니다. 같은 모니터가 모두 연결되면 복원하며, 전체화면·최소화 창은 제외합니다."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if service.enabled {
                helperStatus
                if service.connected {
                    if !needsPermissionCheck {
                        Text(service.state?.permission.message ?? "").foregroundStyle(.secondary).font(.system(size: 11))
                    }
                    if !service.trusted {
                        Text("LookoutWindowHelper · " + L10n.text("창을 저장·복원하려면 손쉬운 사용 권한이 필요합니다."))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if needsPermissionCheck {
                        DisclosureGroup(L10n.text("권한 확인 결과")) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("AXIsProcessTrusted: \(service.state?.permission.trustedAPI == true ? "true" : "false")")
                                Text("AX window query: \(service.state?.permission.query.rawValue ?? "notChecked")")
                                if let code = service.state?.permission.errorCode { Text("AXError: \(String(code))") }
                            }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    Text(service.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saved = service.savedAt {
                    HStack {
                        Text(L10n.text("저장 배치")).foregroundStyle(.secondary)
                        Text(saved, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(L10n.text("지금 복원")) { service.restoreNow() }.disabled(!service.canRestore)
                    }.font(.system(size: 11))
                }
                HStack {
                    Button(L10n.text("현재 배치로 다시 시작")) { confirmsCurrentLayout = true }
                        .disabled(!service.trusted || service.busy)
                    if service.backupAt != nil {
                        Button(L10n.text("이전 배치 복원")) { service.restoreNow(previous: true) }
                            .disabled(!service.canRestore)
                    }
                }.font(.system(size: 11))
                if service.backupAt != nil {
                    Text(L10n.text("이전 정상 배치도 별도 백업으로 보관합니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .alert(L10n.text("현재 배치로 다시 시작할까요?"), isPresented: $confirmsCurrentLayout) {
            Button(L10n.text("취소"), role: .cancel) {}
            Button(L10n.text("저장")) { service.useCurrentLayout() }
        } message: {
            Text(L10n.text("모니터 구성을 변경했거나 창을 새로 정리한 경우 현재 배치를 저장할 수 있습니다. 기존 저장본은 이전 배치로 보관합니다."))
        }
        .onAppear { service.refresh() }
        .onChange(of: appearsActive) { _, active in if active { service.refresh() } }
    }
}
