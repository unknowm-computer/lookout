import Foundation
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func menuBarDensityDefaultsToNormalAndPreservesSavedChoices() throws {
    let name = "LookoutTests.menuBarDensity.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(SettingsStore(defaults: defaults).menuBarDensity == .normal)
    defaults.set("invalid", forKey: "menuBarDensity.v1")
    #expect(SettingsStore(defaults: defaults).menuBarDensity == .normal)
    for density in MenuBarDensity.allCases {
        SettingsStore(defaults: defaults).setMenuBarDensity(density)
        #expect(SettingsStore(defaults: defaults).menuBarDensity == density)
    }
}
