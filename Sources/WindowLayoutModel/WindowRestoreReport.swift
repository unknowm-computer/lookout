import Foundation

public enum WindowRestoreFailure: String, Codable, Sendable {
    case ambiguousIdentity, windowNotFound, appUnresponsive, timeBudget
    case permissionDenied, writeFailed, verificationFailed, displayChanged
}

public struct WindowRestoreIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var app: String
    public var title: String
    public var reason: WindowRestoreFailure
    public var errorCode: Int32?
    public init(id: UUID, app: String, title: String, reason: WindowRestoreFailure, errorCode: Int32? = nil) {
        self.id = id; self.app = String(app.prefix(64)); self.title = String(title.prefix(96))
        self.reason = reason; self.errorCode = errorCode
    }
}

public struct WindowRestoreReport: Codable, Equatable, Sendable {
    public var restored: Int
    public var skipped: Int
    public var failed: Int
    /// Bound the reply size and avoid exposing raw AX data or full document titles.
    public var issues: [WindowRestoreIssue]
    public var interrupted: WindowRestoreFailure?
    public init(restored: Int, skipped: Int, failed: Int, issues: [WindowRestoreIssue]) {
        self.restored = restored; self.skipped = skipped; self.failed = failed
        self.issues = Array(issues.prefix(20))
    }
    public var isValid: Bool {
        [restored, skipped, failed].allSatisfy { (0...200).contains($0) }
            && restored + skipped + failed <= 200 && issues.count <= min(20, failed)
            && Set(issues.map(\.id)).count == issues.count
            && issues.allSatisfy { $0.app.count <= 64 && $0.title.count <= 96 }
            && (interrupted == nil || interrupted == .displayChanged || interrupted == .permissionDenied)
    }
}
