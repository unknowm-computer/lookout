import Foundation
import LookoutCore
@testable import WindowLayoutRuntime
import Testing

private func identityRecord(_ identifier: String, _ title: String, pid: Int32 = 123,
                            documentDigest: Data? = nil) -> LayoutWindow {
    LayoutWindow(bundleID: "fixture", pid: pid, launchDate: Date(timeIntervalSince1970: 1_000),
        identifier: identifier, title: title, displayID: "screen", frame: LayoutRect(x: 0, y: 0, width: 500, height: 400),
        documentDigest: documentDigest)
}

private func match(_ record: LayoutWindow, scope: [LayoutWindow], candidates: [WindowIdentity]) -> WindowIdentityMatch? {
    WindowIdentityMatcher.match(scope: scope, candidates: candidates, pid: record.pid, launchDate: record.launchDate)[record.id]
}

@Test func sharedFinderIdentifierUsesUniqueTitlesWithoutMatchingByWindowOrder() {
    let saved = [identityRecord("common", "Projects"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads"),
                      WindowIdentity(identifier: "common", title: "Projects")]
    #expect(match(saved[0], scope: saved, candidates: candidates) == .found(1))
    #expect(match(saved[1], scope: saved, candidates: candidates) == .found(0))
}
@Test func identicalFinderFoldersStayAmbiguousEvenWhenOnlyOneCandidateRemains() {
    let saved = [identityRecord("common", "Downloads"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads")]
    #expect(match(saved[0], scope: saved, candidates: candidates) == .ambiguous)
}
@Test func matchingNeverUsesAnIdentifierSharedByOtherSavedWindowsAsAUniqueIdentity() {
    let saved = [identityRecord("common", "Projects"), identityRecord("common", "Downloads")]
    let candidates = [WindowIdentity(identifier: "common", title: "Downloads")]
    #expect(match(saved[0], scope: saved, candidates: candidates) == .ambiguous)
    #expect(match(saved[1], scope: saved, candidates: candidates) == .found(0))
}
@Test func uniqueIdentifiersSurviveTitleChangesAndUniqueTitlesSurviveIdentifierChanges() {
    let record = identityRecord("old-id", "Projects")
    #expect(match(record, scope: [record], candidates: [WindowIdentity(identifier: "old-id", title: "New title")]) == .found(0))
    #expect(match(record, scope: [record], candidates: [WindowIdentity(identifier: "new-id", title: "Projects")]) == .found(0))
    #expect(match(record, scope: [record], candidates: [WindowIdentity(identifier: "new-id", title: "Unknown")]) == .missing)
}
@Test func combinedIdentityCanDistinguishTitlesRepeatedAcrossDifferentIdentifiers() {
    let saved = [identityRecord("one", "Folder"), identityRecord("one", "Other"), identityRecord("two", "Folder")]
    let candidates = saved.reversed().map { WindowIdentity(identifier: $0.identifier, title: $0.title) }
    #expect(match(saved[0], scope: saved, candidates: candidates) == .found(2))
    #expect(match(saved[2], scope: saved, candidates: candidates) == .found(0))
}
@Test func identitiesFromAnotherAppProcessDoNotCreateFalseAmbiguity() {
    let saved = [identityRecord("one", "Folder"), identityRecord("one", "Folder", pid: 456)]
    #expect(match(saved[0], scope: saved, candidates: [WindowIdentity(identifier: "one", title: "Folder")]) == .found(0))
}

@Test func strongerMatchesReserveWindowsBeforeAnotherSavedWindowCanClaimThemByTitle() {
    let staleTitle = identityRecord("", "Projects")
    let originalWindow = identityRecord("projects-id", "Old title")
    let candidates = [WindowIdentity(identifier: "projects-id", title: "Projects")]
    let scope = [staleTitle, originalWindow]
    let matches = WindowIdentityMatcher.match(scope: scope, candidates: candidates, pid: originalWindow.pid,
                                             launchDate: originalWindow.launchDate)
    #expect(matches[originalWindow.id] == .found(0))
    #expect(matches[staleTitle.id] == .ambiguous)

    let withReference = WindowIdentityMatcher.match(scope: scope,
        candidates: [WindowIdentity(identifier: "", title: "Projects")], referenced: [originalWindow.id: 0],
        pid: originalWindow.pid, launchDate: originalWindow.launchDate)
    #expect(withReference[originalWindow.id] == .found(0))
    #expect(withReference[staleTitle.id] == .ambiguous)
}

@Test func aUniqueDocumentIdentifiesARenamedWindowEvenAfterAppRestart() {
    let document = Data(repeating: 1, count: 32)
    let saved = identityRecord("old", "Old title", documentDigest: document)
    let candidates = [WindowIdentity(identifier: "new", title: "New title", documentDigest: document)]
    #expect(match(saved, scope: [saved], candidates: candidates) == .found(0))

    let newLaunch = saved.launchDate.addingTimeInterval(1)
    let restart = WindowIdentityMatcher.match(scope: [saved], candidates: candidates, pid: 456,
                                              launchDate: newLaunch, allowRestartedApp: true)
    #expect(restart[saved.id] == .found(0))

    let withoutDocument = [WindowIdentity(identifier: saved.identifier, title: saved.title)]
    let weakRestart = WindowIdentityMatcher.match(scope: [saved], candidates: withoutDocument, referenced: [saved.id: 0],
                                                  attempting: [saved.id], pid: 456,
                                                  launchDate: newLaunch, allowRestartedApp: true)
    #expect(weakRestart[saved.id] == .missing)
    let multipleInstances = WindowIdentityMatcher.match(scope: [saved], candidates: candidates, pid: 456,
                                                       launchDate: newLaunch)
    #expect(multipleInstances[saved.id] == nil)
}

@Test func retryReservesAWindowAlreadyRestoredAfterRestart() {
    let placed = identityRecord("", "First", documentDigest: Data(repeating: 1, count: 32))
    let failed = identityRecord("", "Second", documentDigest: Data(repeating: 2, count: 32))
    let candidates = [WindowIdentity(identifier: "", title: "Second", documentDigest: failed.documentDigest)]
    let matches = WindowIdentityMatcher.match(scope: [placed, failed], candidates: candidates, referenced: [placed.id: 0],
                                              attempting: [failed.id], pid: 456,
                                              launchDate: placed.launchDate.addingTimeInterval(1), allowRestartedApp: true)
    #expect(matches[placed.id] == .found(0))
    #expect(matches[failed.id] == .ambiguous)
}

@Test func documentMatchesRequireUniqueAndCompleteInformation() {
    let document = Data(repeating: 2, count: 32)
    let first = identityRecord("", "Old", documentDigest: document)
    let second = identityRecord("", "Also old", pid: 345, documentDigest: document)
    let candidate = WindowIdentity(identifier: "", title: "New", documentDigest: document)
    let newLaunch = first.launchDate.addingTimeInterval(1)
    let duplicateSaved = WindowIdentityMatcher.match(scope: [first, second], candidates: [candidate], pid: 456,
                                                      launchDate: newLaunch, allowRestartedApp: true)
    #expect(duplicateSaved[first.id] == .ambiguous)
    #expect(duplicateSaved[second.id] == .ambiguous)
    let duplicateLive = WindowIdentityMatcher.match(scope: [first], candidates: [candidate, candidate], pid: 456,
                                                     launchDate: newLaunch, allowRestartedApp: true)
    #expect(duplicateLive[first.id] == .ambiguous)
    let partial = WindowIdentityMatcher.match(scope: [first], candidates: [candidate], pid: 456,
                                              launchDate: newLaunch, allowRestartedApp: true, documentsComplete: false)
    #expect(partial[first.id] == .missing)
}

@Test func aDifferentKnownDocumentPreventsAnUnrelatedWindowFromMatchingByTitle() {
    let saved = identityRecord("", "Downloads", documentDigest: Data(repeating: 1, count: 32))
    let candidates = [WindowIdentity(identifier: "", title: "Downloads", documentDigest: Data(repeating: 2, count: 32))]
    #expect(match(saved, scope: [saved], candidates: candidates) == .ambiguous)
}

@Test func olderSavedLayoutsDecodeWithoutDocumentDigests() throws {
    let record = identityRecord("saved-id", "Saved title")
    let data = try JSONEncoder().encode(record)
    let previousPayload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(previousPayload["documentDigest"] == nil)
    let decoded = try JSONDecoder().decode(LayoutWindow.self, from: data)
    #expect(decoded == record)
}
