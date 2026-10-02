import AppKit
import SwiftUI

struct LoginItemSettingsView: View {
    @StateObject private var service = LoginItemService()
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { service.isEnabled },
                set: { enabled in Task { await service.setEnabled(enabled) } }
            )).toggleStyle(.checkbox).disabled(service.isChanging)
            Text(service.isChanging ? "자동 실행 설정을 변경하는 중…" : service.statusMessage)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let error = service.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top) {
                Text("응용 프로그램 폴더에 설치한 앱에서 설정하세요. 재부팅 후 로그인하면 메뉴바에서 시작합니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("로그인 항목 열기") { service.openSystemSettings() }
                    .font(.system(size: 10))
            }
        }
        .onAppear { service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refresh()
        }
        // System Settings may finish applying a change after the activation notification.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            service.refresh()
        }
    }
}
