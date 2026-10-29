import Foundation
@testable import LookoutCore
import Testing

private func display(_ id: String = "external", x: Double = -1920, y: Double = -1080) -> LayoutDisplay {
    LayoutDisplay(id: id, frame: LayoutRect(x: x, y: y, width: 1920, height: 1080),
                  visibleFrame: LayoutRect(x: x, y: y + 25, width: 1920, height: 1000))
}
private func window(_ id: String = "external") -> LayoutWindow {
    LayoutWindow(bundleID: "app.fixture", pid: 123, launchDate: Date(), identifier: "window", title: "Fixture",
                 displayID: id, frame: LayoutRect(x: 100, y: 50, width: 800, height: 600))
}
@Test func layoutRequiresCompleteDisplayIdentityAndResolutionButAllowsNewOrigins() {
    let saved = [display(), display("internal", x: 0, y: 0)]
    #expect(LayoutDisplay.matches(saved, [display("internal", x: 1920, y: 400), display(x: 0, y: 0)]))
    #expect(!LayoutDisplay.matches(saved, [saved[0]]))
    #expect(!LayoutDisplay.matches(saved, [saved[0], saved[0]]))
    var changed = saved; changed[0].frame.width = 1600
    #expect(!LayoutDisplay.matches(saved, changed))
    #expect(!LayoutDisplay.matches([], []))
}
@Test func layoutUsesDisplayRelativeCoordinatesIncludingDisplaysAboveAndLeft() {
    let saved = window()
    #expect(saved.target(on: [display()]) == LayoutRect(x: -1820, y: -1030, width: 800, height: 600))
    #expect(saved.target(on: [display(x: 1920, y: 0)]) == LayoutRect(x: 2020, y: 50, width: 800, height: 600))
    #expect(saved.target(on: [display("other")]) == nil)
}
@Test func layoutClampsOversizedAndOffscreenWindowsToVisibleArea() {
    let visible = display(x: 0, y: 0).visibleFrame
    let oversized = LayoutRect(x: -500, y: -500, width: 3000, height: 2000).fitted(to: visible)
    #expect(oversized == visible)
    #expect(LayoutRect(x: 1900, y: 1000, width: 800, height: 600).fitted(to: visible)
        == LayoutRect(x: 1120, y: 425, width: 800, height: 600))
}
@Test func layoutRejectsCorruptEmptyDuplicateAndNonfiniteSnapshots() throws {
    var saved = WindowLayoutSnapshot(displays: [display()], windows: [window()])
    #expect(saved.isValid)
    #expect(WindowLayoutSnapshot.decode(try JSONEncoder().encode(saved)) == saved)
    #expect(WindowLayoutSnapshot.decode(Data("invalid".utf8)) == nil)
    #expect(WindowLayoutSnapshot.decode(Data(repeating: 0, count: 1_048_577)) == nil)
    saved.windows.append(saved.windows[0]); #expect(!saved.isValid)
    saved.windows.removeLast(); saved.windows[0].frame.x = .infinity; #expect(!saved.isValid)
    saved.windows = []; #expect(!saved.isValid)
    saved.windows = [window("missing")]; #expect(!saved.isValid)
}
