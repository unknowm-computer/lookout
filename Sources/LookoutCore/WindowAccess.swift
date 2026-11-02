import Foundation
@_exported import WindowLayoutModel

extension WindowAccessReport {
    public var message: String {
        switch query {
        case .allowed: L10n.text("손쉬운 사용 허용됨 · 실제 창 조회 확인")
        case .denied: L10n.text("손쉬운 사용 허용 필요 · 실제 창 접근 거부")
        case .unavailable: trustedAPI ? L10n.text("권한 허용 확인 · 창 조회 응답 확인 불가") : L10n.text("권한 확인 불가 · 다시 확인해주세요.")
        case .notChecked: trustedAPI ? L10n.text("손쉬운 사용 허용됨") : L10n.text("손쉬운 사용 권한 확인이 필요합니다.")
        }
    }
}

extension WindowLayoutPhase {
    public var message: String {
        switch self {
        case .disabled: L10n.text("자동 저장·복원이 꺼져 있습니다.")
        case .permission: L10n.text("창을 저장·복원하려면 손쉬운 사용 권한이 필요합니다.")
        case .ready: L10n.text("첫 정상 배치를 저장할 준비 중입니다.")
        case .saved: L10n.text("정상 배치를 보관 중입니다. 잠자기 전에 다시 저장합니다.")
        case .waiting: L10n.text("저장된 모니터 구성이 안정될 때까지 기다립니다. 기존 배치는 보관합니다.")
        case .restoring: L10n.text("창 배치를 복원하는 중…")
        case .restored(let count, let skipped): L10n.text("\(count)개 창 복원 · \(skipped)개 건너뜀")
        case .incomplete: L10n.text("일부 창을 복원하지 못했습니다. 기존 배치를 보관합니다.")
        case .captureFailed: L10n.text("정상 배치를 저장하지 못했습니다. 기존 배치는 유지합니다.")
        }
    }
}

extension WindowRestoreReport {
    public var summary: String { L10n.text("\(restored)개 창 복원 · \(skipped)개 건너뜀 · \(failed)개 실패") }
}

extension WindowRestoreFailure {
    public var message: String {
        switch self {
        case .ambiguousIdentity: L10n.text("같은 식별자·제목의 창이 여러 개여서 구분할 수 없습니다.")
        case .windowNotFound: L10n.text("저장된 창을 찾지 못했습니다. 창 제목이 변경되었거나 닫혔을 수 있습니다.")
        case .appUnresponsive: L10n.text("앱의 창 조회에 응답이 없거나 오류가 발생했습니다.")
        case .timeBudget: L10n.text("복원 시간 제한에 도달했습니다. 다시 복원하면 재시도합니다.")
        case .permissionDenied: L10n.text("창 접근 권한이 거부되었습니다.")
        case .writeFailed: L10n.text("앱이 창의 위치·크기 변경을 허용하지 않았습니다.")
        case .verificationFailed: L10n.text("변경 요청 후 창의 위치·크기가 저장된 배치와 일치하지 않습니다.")
        case .displayChanged: L10n.text("복원 도중 모니터 작업 영역이 바뀌었습니다. 안정된 후 다시 복원해주세요.")
        }
    }
}
