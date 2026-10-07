import LookoutCore
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateService
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("Lookout 업데이트")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(updates.version).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(updates.status).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("새 버전 자동으로 확인"), isOn: Binding(get: { updates.automaticChecks }, set: updates.setAutomaticChecks))
                .toggleStyle(.checkbox).disabled(updates.configuration == nil)
            Text(L10n.text("새 버전을 찾으면 알려드립니다. 설치 및 재실행은 직접 선택합니다."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let date = updates.lastCheck {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("마지막 확인")).foregroundStyle(.secondary)
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }.font(.system(size: 10))
                }
                Spacer()
                Button(L10n.text("업데이트 확인…")) { updates.check() }.disabled(!updates.canCheck)
            }
        }.padding(18).frame(width: 320).buttonStyle(PanelActionButtonStyle()).onAppear { updates.start() }
    }
}
