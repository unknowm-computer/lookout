import Combine
import LookoutCore
import SwiftUI

@MainActor private final class SpacingViewModel: ObservableObject {
    @Published var spacing: Double = 8
    @Published var padding: Double = 8
    @Published var currentDescription = ""
    @Published var message = "실험적 기능 · 현재 macOS에서 실제 간격 반영은 아직 검증되지 않았습니다."
    @Published var hasOriginal = false
    @Published var needsConflictDecision = false
    @Published var available = true
    private let engine: SpacingEngine?
    init() {
        do {
            engine = try SpacingEngine(preferences: HostSpacingPreferences(), persistence: DefaultsSpacingPersistence())
        } catch { engine = nil; available = false; message = error.localizedDescription }
        if let values = try? engine?.current() {
            if let value = try? values.spacing.value() as? NSNumber, (4...24).contains(value.doubleValue) { spacing = value.doubleValue }
            if let value = try? values.padding.value() as? NSNumber, (4...24).contains(value.doubleValue) { padding = value.doubleValue }
        }
        refresh()
    }
    func refresh() {
        guard let engine else { return }
        do {
            let values = try engine.current()
            let gap = try values.spacing.value(), pad = try values.padding.value()
            currentDescription = "간격 \(gap.map { String(describing: $0) } ?? "시스템 기본") · 클릭 여백 \(pad.map { String(describing: $0) } ?? "시스템 기본")"
            hasOriginal = engine.transaction != nil
        } catch { message = error.localizedDescription }
    }
    func apply() {
        guard let engine else { return }
        do {
            try engine.apply(spacing: Int(spacing), padding: Int(padding))
            message = "설정 저장됨 · 실제 반영 대기. 메뉴바 앱 재실행 또는 로그아웃 후 확인하세요."
        } catch { message = error.localizedDescription }
        refresh()
    }
    func restore(force: Bool = false) {
        guard let engine else { return }
        do {
            try engine.restore(overridingExternalChange: force)
            message = "원래 설정 복원됨 · 메뉴바 앱 재실행 또는 로그아웃 후 확인하세요."
        } catch SpacingError.conflict {
            needsConflictDecision = true
        } catch { message = error.localizedDescription }
        refresh()
    }
}

struct SpacingSettingsView: View {
    @StateObject private var model = SpacingViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("메뉴바 전체 아이콘 간격").font(.system(size: 13, weight: .semibold))
            Text("다른 앱을 포함한 메뉴바 아이콘 사이의 여백을 조절합니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("좁게") { model.spacing = 4; model.padding = 4 }
                Button("보통") { model.spacing = 8; model.padding = 8 }
                Button("넓게") { model.spacing = 16; model.padding = 16 }
                Spacer()
            }
            slider("아이콘 간격", value: $model.spacing)
            slider("클릭 여백", value: $model.padding)
            VStack(alignment: .leading, spacing: 7) {
                Text("예상 배치").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: model.spacing) {
                    ForEach(["chart.bar.xaxis", "bell", "cloud", "wifi", "battery.75percent"], id: \.self) { symbol in
                        Image(systemName: symbol).padding(.horizontal, model.padding / 2)
                    }
                }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 36)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("메뉴바 간격 예상 배치")
            }
            Text(model.currentDescription).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("적용") { model.apply() }.buttonStyle(PanelActionButtonStyle(prominent: true)).disabled(!model.available)
                Button("원래 값으로 복원") { model.restore() }.disabled(!model.hasOriginal)
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("현재 메뉴바 간격 설정 확인")
            }
            Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("미리보기는 예상 모습입니다. 실제 메뉴바 반영은 macOS에 따라 다릅니다.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .alert("다른 앱에서 설정을 변경했습니다", isPresented: $model.needsConflictDecision) {
            Button("취소", role: .cancel) {}
            Button("보관된 원래 값으로 복원", role: .destructive) { model.restore(force: true) }
        } message: {
            Text("현재 외부 변경을 덮어쓰고 Lookout 최초 적용 전의 설정으로 돌아갑니다.")
        }
    }
    private func slider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 11)).frame(width: 72, alignment: .leading)
            Slider(value: value, in: 4...24, step: 1).accessibilityLabel(title)
            Text("\(Int(value.wrappedValue))").monospacedDigit().font(.system(size: 11)).frame(width: 24)
        }
    }
}
