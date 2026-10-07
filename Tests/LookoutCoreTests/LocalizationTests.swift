import Foundation
@testable import LookoutCore
import Testing

@Test func localizationCatalogsHaveMatchingKeysAndArguments() throws {
    func catalog(_ language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language).lproj"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
    let english = try catalog("en"), korean = try catalog("ko")
    #expect(english.count >= 319)
    #expect(Set(english.keys) == Set(korean.keys))
    let expression = try NSRegularExpression(pattern: #"\{\d+\}"#)
    func arguments(_ string: String) -> [String] {
        expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
            .compactMap { Range($0.range, in: string).map { String(string[$0]) } }.sorted()
    }
    for (key, translation) in english {
        #expect(!translation.isEmpty)
        #expect(korean[key] == key)
        #expect(arguments(key) == arguments(translation))
        #expect(translation.range(of: "[가-힣]", options: .regularExpression) == nil)
    }
}

@Test func localizationSupportsKoreanEnglishAndRegionalPreferences() {
    #expect(L10n.text("메모리", language: "ko-KR") == "메모리")
    #expect(L10n.text("메모리", language: "en-GB") == "Memory")
    #expect(L10n.text("메모리", language: "fr") == "Memory")
    #expect(L10n.text("사용 용량", language: "en") == "Used space")
    #expect(L10n.text("최근 5분 기록", language: "en") == "Last 5 minutes")
}

@Test func localizationPreservesInterpolatedValuesAndSupportsArgumentReordering() {
    #expect(L10n.text("Intel Mac에서는 \("GPU") 모니터링을 지원하지 않습니다.", language: "en")
            == "GPU monitoring is not supported on Intel Macs.")
    #expect(L10n.text("\(2)시간 \(5)분", language: "en") == "2 hr 5 min")
    #expect(L10n.text("\(2)시간 \(5)분", language: "ko") == "2시간 5분")
    #expect(L10n.text("\(20) \("%") \("at least") 10초 유지 시 해제", language: "en")
            == "Clears after staying at least 20 % for 10 seconds")
    let name = "Helper {1} · 25%"
    #expect(L10n.text("사용 \(name), 여유 \("4 GiB")", language: "en")
            == "Used Helper {1} · 25%, available 4 GiB")
    #expect(L10n.text("\(42)%", language: "en") == "42%")
}
