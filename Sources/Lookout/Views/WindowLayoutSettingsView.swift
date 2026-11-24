import LookoutCore
import SwiftUI
import WindowHelperProtocol

struct WindowLayoutSettingsView: View {
    @ObservedObject var service: WindowLayoutClient
    @State private var showsDetails = false
    @State private var confirmsSave = false
    @State private var hoveringSavedLayout = false
    @State private var showsRestoreResult = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("창 배치 자동 복원")).fontWeight(.semibold)
                    Text(L10n.text("잠자기·화면 절전에서 돌아오거나 잠금을 해제하면 창을 복원합니다."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle(L10n.text("창 배치 자동 복원"), isOn: Binding(
                    get: { service.enabled }, set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(L10n.text("잠자기나 화면 절전에서 돌아오거나 잠금을 해제하면 창 배치를 복원합니다. 같은 모니터가 모두 연결되어야 하며 전체화면·최소화 창은 제외합니다."))
            }
            Divider()
            if service.enabled { permissionNotices }
            VStack(alignment: .leading, spacing: 10) {
                intervalRow
                savedLayout
                DisclosureGroup(L10n.text("세부 옵션"), isExpanded: $showsDetails) {
                    advancedOptions
                }
            }
            .disabled(!service.enabled)
        }
        .alert(L10n.text("현재 배치를 저장할까요?"), isPresented: $confirmsSave) {
            Button(L10n.text("취소"), role: .cancel) {}
            Button(L10n.text("저장")) { service.useCurrentLayout() }
        } message: {
            Text(L10n.text("이전 정상 배치도 별도 백업으로 보관합니다."))
        }
        .onAppear { service.refresh() }
        .onChange(of: appearsActive) { _, active in if active { service.refresh() } }
        .onChange(of: service.state?.phase) { previous, phase in
            if case .restored = phase { showsRestoreResult = previous != nil }
            else { showsRestoreResult = false }
        }
        .onChange(of: service.enabled) { _, enabled in
            if !enabled { showsDetails = false }
        }
    }

    private var intervalRow: some View {
        HStack {
            Text(L10n.text("저장 간격"))
            Spacer()
            Picker(L10n.text("저장 간격"), selection: Binding(
                get: { service.captureInterval }, set: { service.setCaptureInterval($0) }
            )) {
                ForEach(WindowLayoutCaptureInterval.allCases, id: \.self) { interval in
                    let seconds = interval.rawValue
                    Text(seconds < 60 ? L10n.text("\(seconds)초") : L10n.text("\(seconds / 60)분"))
                        .tag(interval)
                }
            }.labelsHidden().frame(width: 110)
        }
    }

    private var savedLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if service.savedPreviewAt != nil { Image(systemName: "photo").accessibilityHidden(true) }
                Text(L10n.text("저장된 배치"))
                Spacer(minLength: 4)
                if let saved = service.savedAt {
                    Text(saved, format: .dateTime.month().day().hour().minute())
                        .monospacedDigit().foregroundStyle(.secondary)
                } else if service.connected {
                    Text(L10n.text("저장된 배치가 없습니다.")).foregroundStyle(.secondary)
                }
            }
            .modifier(WindowLayoutPreviewHover(service: service, hovering: $hoveringSavedLayout))
            if let state = service.state {
                HStack {
                    Text(L10n.text("메모리 배치 마지막 갱신"))
                    Spacer(minLength: 4)
                    if let date = state.lastRecentCaptureAt {
                        Text(date, format: .dateTime.month().day().hour().minute().second())
                            .monospacedDigit()
                    } else {
                        Text(L10n.text("갱신 기록 없음"))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text("현재 배치 저장")) {
                    if service.savedAt == nil { service.useCurrentLayout() }
                    else { confirmsSave = true }
                }.disabled(!service.canSave)
                Button(L10n.text("저장된 배치 복원")) { service.restoreNow() }
                    .buttonStyle(PanelActionButtonStyle(prominent: true))
                    .disabled(!service.canRestore)
            }
            if let state = service.state {
                layoutStatus(state)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func layoutStatus(_ state: WindowHelperState) -> some View {
        switch state.phase {
        case .waiting, .restoring, .incomplete, .captureFailed, .displayNotReady:
            Text(state.phase.message)
        case .restored where showsRestoreResult:
            Text(state.phase.message)
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { showsRestoreResult = false }
                }
        default:
            EmptyView()
        }
        if let report = state.restoreReport, report.failed > 0 || report.interrupted != nil {
            Text(report.summary)
            if let interruption = report.interrupted { Text(interruption.message) }
            if !report.issues.isEmpty { WindowLayoutRestoreFailures(report: report) }
        }
        if let notice = service.saveNotice { Text(notice) }
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.text("저장 배치 화면 미리보기"), isOn: Binding(
                get: { service.state?.previewEnabled == true }, set: { service.setPreviewEnabled($0) }
            ))
            .toggleStyle(.checkbox).disabled(!service.connected || service.connecting)
            .help(L10n.text("배치를 저장할 때 모니터별 화면을 작게 캡처해 이 Mac에 보관합니다. 옵션을 끄면 미리보기를 지웁니다."))
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text("이전 배치 복원")) { service.restoreNow(previous: true) }
                    .disabled(service.backupAt == nil || !service.canRestore)
                Button(L10n.text("진단 로그 저장")) { service.exportDiagnostics() }
                    .disabled(!service.connected || service.exportingDiagnostics)
            }
        }.padding(.top, 4)
    }

    private var needsPermissionCheck: Bool {
        service.connected && service.state?.permission.query != .allowed
    }
    private var needsRecovery: Bool {
        service.registration != .enabled || service.needsRefresh || service.connectionError != nil
            || service.maintenance.error != nil || !service.connected || needsPermissionCheck
    }
    private var recoveryMessage: String {
        if service.maintenance.updating { return L10n.text("설정을 복구하고 연결을 확인하는 중입니다.") }
        if service.registration == .requiresApproval { return L10n.text("창 배치 도우미의 백그라운드 실행을 허용해주세요.") }
        if let error = service.maintenance.error ?? service.connectionError { return error }
        if service.needsRefresh || service.registration != .enabled { return L10n.text("창 배치 도우미 등록·연결 설정이 필요합니다.") }
        if let permission = service.state?.permission {
            return permission.canAccess ? permission.message : "LookoutWindowHelper · " + permission.message
        }
        return L10n.text("창 배치 도우미에 연결하는 중입니다.")
    }

    @ViewBuilder private var permissionNotices: some View {
        if needsRecovery || service.maintenance.updating {
            HelperRecoveryRow(message: recoveryMessage, working: service.connecting || service.maintenance.updating,
                needsApproval: service.registration == .requiresApproval, disabled: service.busy,
                recover: { service.install() }, openSettings: { service.openSystemSettings() })
            if needsPermissionCheck, let permission = service.state?.permission {
                DisclosureGroup(L10n.text("권한 확인 결과")) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AXIsProcessTrusted: \(permission.trustedAPI ? "true" : "false")")
                        Text("AX window query: \(permission.query.rawValue)")
                        if let code = permission.errorCode { Text("AXError: \(String(code))") }
                    }.foregroundStyle(.secondary).textSelection(.enabled)
                }.font(.system(size: 11))
            }
        }
        if service.state?.previewEnabled == true && service.state?.screenRecordingAllowed != true {
            HStack {
                Text(L10n.text("미리보기를 사용하려면 창 배치 도우미에 화면 기록 권한을 허용해주세요."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L10n.text("화면 기록 권한 설정")) { service.requestPreviewPermission() }
                    .disabled(service.connecting)
            }.font(.system(size: 11))
        }
    }
}

private struct WindowLayoutRestoreFailures: View {
    let report: WindowRestoreReport

    var body: some View {
        DisclosureGroup(L10n.text("복원 실패 내역")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title.isEmpty ? issue.app : issue.app + " · " + issue.title)
                            .lineLimit(2)
                        Text(issue.reason.message)
                        if let code = issue.errorCode { Text("AXError: \(code)") }
                    }
                }
                if report.failed > report.issues.count {
                    Text(L10n.text("실패 내역은 최대 20개까지 표시합니다."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
