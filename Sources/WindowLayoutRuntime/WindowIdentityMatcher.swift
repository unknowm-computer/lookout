import Foundation
import WindowLayoutModel

struct WindowIdentity: Equatable {
    var identifier: String
    var title: String
}

enum WindowIdentityMatch: Equatable {
    case found(Int), missing, ambiguous
}

enum WindowIdentityMatcher {
    /// Both sides must identify exactly one window. The scope is the full snapshot, even on retry.
    static func match(_ record: LayoutWindow, scope: [LayoutWindow], candidates: [WindowIdentity]) -> WindowIdentityMatch {
        let saved = scope.filter { $0.pid == record.pid && $0.launchDate == record.launchDate && $0.bundleID == record.bundleID }
        let matchingIDs = candidates.indices.filter { !record.identifier.isEmpty && candidates[$0].identifier == record.identifier }
        let savedIDs = saved.filter { !record.identifier.isEmpty && $0.identifier == record.identifier }
        if matchingIDs.count == 1 && savedIDs.count == 1 { return .found(matchingIDs[0]) }

        if !record.title.isEmpty {
            let combined = matchingIDs.filter { candidates[$0].title == record.title }
            if combined.count == 1 && savedIDs.filter({ $0.title == record.title }).count == 1 {
                return .found(combined[0])
            }
            let titles = candidates.indices.filter { candidates[$0].title == record.title }
            if titles.count == 1 && saved.filter({ $0.title == record.title }).count == 1 { return .found(titles[0]) }
            if !titles.isEmpty { return .ambiguous }
        }
        return matchingIDs.isEmpty ? .missing : .ambiguous
    }
}
