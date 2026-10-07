import AppKit
@testable import Lookout
import Testing

@Test @MainActor func languageRestartSavesSettingsAndOpensSameBundleBeforeTermination() async throws {
    let url = URL(fileURLWithPath: "/Applications/Lookout Example.app")
    var events: [String] = []
    let relauncher = AppRelauncher(applicationURL: url,
        synchronize: { events.append("save"); return true },
        openApplication: { target, configuration in
            #expect(target == url)
            #expect(configuration.createsNewApplicationInstance)
            #expect(configuration.arguments == ["--settings"])
            #expect(configuration.activates)
            events.append("launch")
            return ProcessInfo.processInfo.processIdentifier + 1
        }, terminate: { events.append("terminate") })
    try await relauncher.restart()
    #expect(events == ["save", "launch", "terminate"])
}

@Test @MainActor func failedLanguageRestartKeepsTheOriginalAppRunning() async {
    enum LaunchFailure: Error { case failed }
    for scenario in ["save", "launch", "same-instance", "not-app"] {
        var terminated = false, launchCalls = 0
        let relauncher = AppRelauncher(
            applicationURL: URL(fileURLWithPath: scenario == "not-app" ? "/tmp/Lookout" : "/Applications/Lookout.app"),
            synchronize: { scenario != "save" },
            openApplication: { _, _ in
                launchCalls += 1
                if scenario == "launch" { throw LaunchFailure.failed }
                return ProcessInfo.processInfo.processIdentifier
            }, terminate: { terminated = true })
        do { try await relauncher.restart(); Issue.record("A failed restart must throw") }
        catch {}
        #expect(!terminated)
        #expect(launchCalls == (["save", "not-app"].contains(scenario) ? 0 : 1))
    }
}
