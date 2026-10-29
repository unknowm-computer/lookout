import Foundation
@_exported import FanSupport

extension CoolingMode {
    public var title: String {
        switch self {
        case .system: L10n.text("시스템 자동")
        case .comfortable: L10n.text("쾌적")
        case .intensive: L10n.text("적극 냉각")
        }
    }
    public var description: String {
        switch self {
        case .system: L10n.text("macOS가 팬 속도를 조절합니다.")
        case .comfortable: L10n.text("온도가 오르면 팬을 일찍 가속합니다. 소음이 늘어날 수 있습니다.")
        case .intensive: L10n.text("소음보다 냉각을 우선합니다.")
        }
    }
}

extension CoolingTemperatureBand {
    public var title: String {
        switch self {
        case .normal: L10n.text("일반")
        case .warm: L10n.text("온도 높음")
        case .hot: L10n.text("온도 매우 높음")
        }
    }
}

extension CoolingFan {
    public var title: String {
        id == 0 ? L10n.text("왼쪽 팬") : L10n.text("오른쪽 팬")
    }
}

extension ValueFormat {
    public static func temperature(_ value: Double) -> String {
        guard value.isFinite, (0...120).contains(value) else { return "—" }
        return String(format: "%.0f°C", value)
    }
    public static func rpm(_ value: Double) -> String {
        guard value.isFinite, (0...12000).contains(value) else { return "—" }
        return String(format: "%.0f RPM", value)
    }
}
