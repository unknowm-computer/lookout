import LookoutCore
import SwiftUI

struct SleepPreventersView: View {
    let preventers: [SleepPreventer]?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preventers, !preventers.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preventers) { process in
                            HStack(alignment: .top, spacing: 5) {
                                ProcessIcon(id: process.processID)
                                Text(process.name)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .help("\(process.name) · PID \(process.pid)")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(process.name), PID \(process.pid)")
                        }
                    }.padding(.top, 5)
                } label: { header }
                    .tint(.secondary)
                    .accessibilityIdentifier("sleep-preventers")
                if !expanded {
                    Text(preventers.prefix(3).map(\.name).joined(separator: ", ")
                         + (preventers.count > 3 ? L10n.text(" 외 \(preventers.count - 3)개") : ""))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                header
            }
        }
        .font(.system(size: 10))
        .onChange(of: preventers?.isEmpty ?? true) { _, empty in
            if empty { expanded = false }
        }
        .onDisappear { expanded = false }
    }

    private var header: some View {
        HStack {
            Text(L10n.text("잠자기 방지")).foregroundStyle(.secondary)
            Spacer()
            Text(preventers.map { $0.isEmpty ? L10n.text("없음") : L10n.text("\($0.count)개 프로세스") }
                 ?? L10n.text("확인 불가"))
        }
    }
}
