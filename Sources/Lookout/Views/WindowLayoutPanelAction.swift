import LookoutCore
import SwiftUI

struct WindowLayoutPanelAction: View {
    @ObservedObject var service: WindowLayoutClient
    let presented: Bool
    @State private var showingActions = false

    var body: some View {
        if service.enabled && presented {
            Button { showingActions.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow").accessibilityHidden(true)
                    Text(L10n.text("창 배치"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
                }
            }
            .font(.system(size: 11))
            .buttonStyle(PanelActionButtonStyle(borderless: true, horizontalPadding: 4))
            .popover(isPresented: $showingActions, arrowEdge: .bottom) {
                WindowLayoutActionsPopover(service: service)
            }
            .onDisappear { showingActions = false }
        }
    }
}

private struct WindowLayoutActionsPopover: View {
    @ObservedObject var service: WindowLayoutClient
    @State private var confirmsSave = false
    @State private var hoveringRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let savedAt = service.savedAt {
                HStack {
                    Text(L10n.text("저장 배치"))
                    Spacer(minLength: 8)
                    Text(savedAt, format: .dateTime.month().day().hour().minute())
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("저장된 배치가 없습니다.")).foregroundStyle(.secondary)
            }

            if confirmsSave {
                Text(L10n.text("현재 배치를 저장할까요?")).fontWeight(.semibold)
                Text(L10n.text("이전 정상 배치도 별도 백업으로 보관합니다.")).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L10n.text("취소")) { confirmsSave = false }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        confirmsSave = false
                        service.useCurrentLayout()
                    } label: {
                        Label(L10n.text("저장"), systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(PanelActionButtonStyle(prominent: true))
                    .disabled(!service.canSave)
                }
                .buttonStyle(PanelActionButtonStyle())
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    restoreAction
                    Divider().padding(.vertical, 3)
                    action("현재 배치 저장", symbol: "tray.and.arrow.down") {
                        if service.savedAt == nil { service.useCurrentLayout() }
                        else { confirmsSave = true }
                    }
                    .disabled(!service.canSave)
                }
            }

            Group {
                status
                if let notice = service.saveNotice { Text(notice) }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .frame(width: 220, alignment: .leading)
        .padding(12)
        .onChange(of: service.savedAt) { _, _ in confirmsSave = false }
    }

    private var restoreAction: some View {
        ZStack {
            action("저장된 배치 복원", symbol: "arrow.uturn.backward") {
                hoveringRestore = false
                service.restoreNow()
            }
            .disabled(!service.canRestore)
        }
        .modifier(WindowLayoutPreviewHover(service: service, hovering: $hoveringRestore))
    }

    private func action(_ title: LocalizedText, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 14).accessibilityHidden(true)
                Text(L10n.text(title))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelActionButtonStyle(borderless: true, horizontalPadding: 5))
    }

    @ViewBuilder private var status: some View {
        if let error = service.maintenance.error ?? service.connectionError {
            Text(error)
        } else if service.connecting && !service.connected {
            Text(L10n.text("창 배치 도우미에 연결하는 중입니다."))
        } else if service.state?.phase != .saved {
            Text(service.statusMessage)
            if let report = service.state?.restoreReport, report.failed > 0 || report.interrupted != nil {
                Text(report.summary)
                if let interruption = report.interrupted { Text(interruption.message) }
            }
        }
    }
}
