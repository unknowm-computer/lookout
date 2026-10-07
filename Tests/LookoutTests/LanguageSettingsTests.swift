import Foundation
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func languageOverridePersistsAndCanReturnToSystemWithoutChangingMonitoring() throws {
    let name = "LookoutTests.language.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SettingsStore(defaults: defaults)
    let configuration = store.configuration, alerts = store.alerts, charts = store.charts
    let systemLanguages = defaults.stringArray(forKey: "AppleLanguages")
    let activeLanguage = L10n.language
    #expect(store.language == .system)
    for choice in [AppLanguage.english, .korean, .system] {
        store.setLanguage(choice)
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.language == choice)
        #expect(restored.configuration == configuration && restored.alerts == alerts && restored.charts == charts)
        #expect(L10n.language == activeLanguage)
    }
    #expect(defaults.stringArray(forKey: "AppleLanguages") == systemLanguages)
    #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
    #expect(defaults.data(forKey: SettingsStore.key) == nil)
}

@Test @MainActor func invalidLanguagePreferenceFallsBackToSystem() throws {
    let name = "LookoutTests.invalidLanguage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
    #expect(SettingsStore(defaults: defaults).language == .system)
    #expect(AppLanguage.system.localization == nil)
    #expect(AppLanguage.korean.localization == "ko")
    #expect(AppLanguage.english.localization == "en")
}
