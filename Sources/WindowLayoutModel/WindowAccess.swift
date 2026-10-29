import Foundation

public struct WindowAccessReport: Codable, Equatable, Sendable {
    public enum Query: String, Codable, Sendable { case allowed, denied, unavailable, notChecked }
    public var trustedAPI: Bool
    public var query: Query
    public var errorCode: Int32?
    public var checkedAt: Date
    public var canAccess: Bool { query == .allowed || (trustedAPI && query != .denied) }
    public init(trustedAPI: Bool, query: Query, errorCode: Int32? = nil, checkedAt: Date = Date()) {
        self.trustedAPI = trustedAPI; self.query = query; self.errorCode = errorCode; self.checkedAt = checkedAt
    }

}

public enum WindowLayoutPhase: Codable, Equatable, Sendable {
    case disabled, permission, ready, saved, waiting, restoring, restored(Int, Int), incomplete, captureFailed

}
