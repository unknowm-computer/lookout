import Foundation

public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicKey: String
    public static func validate(feedURL: String?, publicKey: String?) throws -> UpdateConfiguration? {
        let feed = (feedURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (publicKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if feed.isEmpty && key.isEmpty { return nil }
        guard !feed.isEmpty && !key.isEmpty else { throw UpdateConfigurationError.incomplete }
        guard let components = URLComponents(string: feed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw UpdateConfigurationError.invalidFeed }
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else { throw UpdateConfigurationError.invalidKey }
        return UpdateConfiguration(feedURL: url, publicKey: key)
    }
}

public enum UpdateConfigurationError: LocalizedError {
    case incomplete, invalidFeed, invalidKey
    public var errorDescription: String? {
        switch self {
        case .incomplete: "업데이트 배포 설정이 아직 완료되지 않았습니다."
        case .invalidFeed: "업데이트 주소 설정을 확인해야 합니다."
        case .invalidKey: "업데이트 검증 키 설정을 확인해야 합니다."
        }
    }
}
