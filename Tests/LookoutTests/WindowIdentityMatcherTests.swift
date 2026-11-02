import Foundation
import LookoutCore
@testable import WindowLayoutRuntime
import Testing

private func identityRecord(_ identifier: String, _ title: String, pid: Int32 = 123) -> LayoutWindow {
    LayoutWindow(bundleID: "fixture", pid: pid, launchDate: Date(timeIntervalSince1970: 1_000),
        identifier: identifier, title: title, displayID: "screen", frame: LayoutRect(x: 0, y: 0, width: 500, height: 400))
}

@Test func sharedFinderIdentifierUsesUniqueTitlesWithoutMatchingByWindowOrder() {
    let saved = [identityRecord("common", "Projects"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads"),
                      WindowIdentity(identifier: "common", title: "Projects")]
    #expect(WindowIdentityMatcher.match(saved[0], scope: saved, candidates: candidates) == .found(1))
    #expect(WindowIdentityMatcher.match(saved[1], scope: saved, candidates: candidates) == .found(0))
}
@Test func identicalFinderFoldersStayAmbiguousEvenWhenOnlyOneCandidateRemains() {
    let saved = [identityRecord("common", "Downloads"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads")]
    #expect(WindowIdentityMatcher.match(saved[0], scope: saved, candidates: candidates) == .ambiguous)
}
@Test func matchingNeverUsesAnIdentifierSharedByOtherSavedWindowsAsAUniqueIdentity() {
    let saved = [identityRecord("common", "Projects"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads")]
    #expect(WindowIdentityMatcher.match(saved[0], scope: saved, candidates: candidates) == .ambiguous)
    #expect(WindowIdentityMatcher.match(saved[1], scope: saved, candidates: candidates) == .found(0))
}
@Test func uniqueIdentifiersSurviveTitleChangesAndUniqueTitlesSurviveIdentifierChanges() {
    let record = identityRecord("old-id", "Projects")
    #expect(WindowIdentityMatcher.match(record, scope: [record], candidates: [WindowIdentity(identifier: "old-id", title: "New title")]) == .found(0))
    #expect(WindowIdentityMatcher.match(record, scope: [record], candidates: [WindowIdentity(identifier: "new-id", title: "Projects")]) == .found(0))
    #expect(WindowIdentityMatcher.match(record, scope: [record], candidates: [WindowIdentity(identifier: "new-id", title: "Unknown")]) == .missing)
}
@Test func combinedIdentityCanDistinguishTitlesRepeatedAcrossDifferentIdentifiers() {
    let saved = [identityRecord("one", "Folder"), identityRecord("one", "Other"), identityRecord("two", "Folder")]
    let candidates = saved.reversed().map { WindowIdentity(identifier: $0.identifier, title: $0.title) }
    #expect(WindowIdentityMatcher.match(saved[0], scope: saved, candidates: candidates) == .found(2))
    #expect(WindowIdentityMatcher.match(saved[2], scope: saved, candidates: candidates) == .found(0))
}
@Test func identitiesFromAnotherAppProcessDoNotCreateFalseAmbiguity() {
    let saved = [identityRecord("one", "Folder"), identityRecord("one", "Folder", pid: 456)]
    #expect(WindowIdentityMatcher.match(saved[0], scope: saved, candidates: [WindowIdentity(identifier: "one", title: "Folder")]) == .found(0))
}
