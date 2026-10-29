import LookoutCore
import SwiftUI

/// Both helper features expose the same recovery/OS-approval interaction.
struct HelperRecoveryRow: View {
    let message: String
    var working = false
    var needsApproval = false
    var showsAction = true
    var disabled = false
    let recover: () -> Void
    let openSettings: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small) }
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showsAction && !working {
                Spacer(minLength: 3)
                Button(needsApproval ? L10n.text("시스템 설정에서 허용") : L10n.text("설정 복구"),
                       action: needsApproval ? openSettings : recover)
                    .fixedSize().disabled(disabled)
                    .help(L10n.text("등록·연결을 확인합니다. macOS 승인이 필요하면 해당 설정으로 안내합니다."))
            }
        }.font(.system(size: 11))
    }
}
