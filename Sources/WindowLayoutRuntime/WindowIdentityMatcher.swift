import Foundation
import WindowLayoutModel

struct WindowIdentity {
    var identifier: String
    var title: String
    var documentDigest: Data? = nil
}

enum WindowIdentityMatch: Equatable {
    case found(Int), missing, ambiguous
}

enum WindowIdentityMatcher {
    private struct IdentifierAndTitle: Hashable {
        let identifier: String
        let title: String

        init?(_ identifier: String, _ title: String) {
            guard !identifier.isEmpty, !title.isEmpty else { return nil }
            self.identifier = identifier
            self.title = title
        }
    }

    /// Scope contains every saved window of the bundle, including those already placed on a retry.
    static func match(scope: [LayoutWindow], candidates: [WindowIdentity], referenced: [UUID: Int] = [:],
                      attempting: Set<UUID>? = nil,
                      pid: Int32, launchDate: Date, allowRestartedApp: Bool = false,
                      documentsComplete: Bool = true) -> [UUID: WindowIdentityMatch] {
        let original = scope.filter { $0.pid == pid && $0.launchDate == launchDate }
        let originalIDs = Set(original.map(\.id))
        let eligible = allowRestartedApp ? scope : original
        var matches: [UUID: WindowIdentityMatch] = [:]
        var claimed = Set<Int>()
        var ambiguous = Set<UUID>()

        // Reserve surviving AX references before a metadata match can claim any of their windows.
        let referencePairs = eligible.compactMap { record -> (UUID, Int)? in
            // A previously restored window may still need reserving on a retry. A new restore
            // after relaunch must verify the document again, even if its last AX reference survived.
            guard originalIDs.contains(record.id) || attempting?.contains(record.id) == false,
                  let index = referenced[record.id] else { return nil }
            return (record.id, index)
        }
        let references = Dictionary(grouping: referencePairs, by: { $0.1 })
        for (index, records) in references {
            claimed.insert(index)
            for (id, _) in records { matches[id] = records.count == 1 ? .found(index) : .ambiguous }
        }

        func assign<Key: Hashable>(_ records: [LayoutWindow], savedKey: (LayoutWindow) -> Key?,
                                   candidateKey: (WindowIdentity) -> Key?, only eligibleIDs: Set<UUID>? = nil) {
            // Count duplicates in the original scope, even when a stronger match already used one.
            let stored = Dictionary(grouping: records.compactMap { record in savedKey(record).map { ($0, record) } },
                                    by: { $0.0 })
            let live = Dictionary(grouping: candidates.indices.compactMap { index in candidateKey(candidates[index]).map { ($0, index) } },
                                  by: { $0.0 })
            for (key, records) in stored {
                guard let windows = live[key] else { continue }
                for (_, record) in records where matches[record.id] == nil && (eligibleIDs?.contains(record.id) ?? true) {
                    let index = windows[0].1
                    guard records.count == 1, windows.count == 1, !claimed.contains(index) else {
                        ambiguous.insert(record.id)
                        continue
                    }
                    if let saved = record.documentDigest, let current = candidates[index].documentDigest, saved != current {
                        ambiguous.insert(record.id)
                        continue
                    }
                    matches[record.id] = .found(index)
                    claimed.insert(index)
                }
            }
        }

        assign(original, savedKey: { $0.identifier.isEmpty ? nil : $0.identifier },
               candidateKey: { $0.identifier.isEmpty ? nil : $0.identifier })
        if documentsComplete {
            assign(original, savedKey: \.documentDigest, candidateKey: \.documentDigest)
            if allowRestartedApp {
                let restarted = Set(scope.map(\.id)).subtracting(originalIDs)
                assign(scope, savedKey: \.documentDigest, candidateKey: \.documentDigest, only: restarted)
            }
        }
        assign(original, savedKey: { IdentifierAndTitle($0.identifier, $0.title) },
               candidateKey: { IdentifierAndTitle($0.identifier, $0.title) })
        assign(original, savedKey: { $0.title.isEmpty ? nil : $0.title },
               candidateKey: { $0.title.isEmpty ? nil : $0.title })

        for record in eligible where matches[record.id] == nil {
            matches[record.id] = ambiguous.contains(record.id) ? .ambiguous : .missing
        }
        return matches
    }
}
