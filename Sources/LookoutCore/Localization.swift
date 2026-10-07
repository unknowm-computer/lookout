import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, korean = "ko", english = "en"
    public static let preferenceKey = "appLanguage.v1"
    public var id: String { rawValue }
    public var localization: String? { self == .system ? nil : rawValue }
    public var title: String {
        switch self {
        case .system: L10n.text("시스템 설정 따름")
        case .korean: "한국어"
        case .english: "English"
        }
    }
    public static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}

/// Shared by SwiftUI, AppKit, collectors and notifications. Resource lookup follows
/// the app override or macOS preferences, captured for one launch to avoid mixed languages.
public enum L10n {
    public static let supportedLanguages = ["en", "ko"]
    public static let language = AppLanguage.load().localization ?? Bundle.module.preferredLocalizations.first ?? "en"
    private static let currentBundle = localizedBundle(for: language) ?? .module
    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)

    private static func localizedBundle(for language: String) -> Bundle? {
        if let selected = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: [language]).first,
           let path = Bundle.module.path(forResource: selected, ofType: "lproj"),
           let localized = Bundle(path: path) { return localized }
        return nil
    }

    public static func text(_ value: LocalizedText, language: String? = nil) -> String {
        let bundle = language.flatMap(localizedBundle(for:)) ?? currentBundle
        var result = bundle.localizedString(forKey: value.key, value: value.key, table: "Localizable")
        guard !value.arguments.isEmpty else { return result }
        let matches = placeholder.matches(in: result, range: NSRange(result.startIndex..., in: result))
        // Replace from the end so translated arguments can be reordered without changing ranges.
        // Values are inserted once: a process name containing "{0}" is never interpreted again.
        for match in matches.reversed() {
            guard let indexRange = Range(match.range(at: 1), in: result),
                  let index = Int(result[indexRange]), value.arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: value.arguments[index])
        }
        return result
    }
}

/// Literal segments form a catalog key; interpolated readings/names remain separate values.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}
