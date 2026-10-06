import AppKit
import LookoutCore
@testable import Lookout
import Testing

@Test @MainActor func processIconsReuseAppThumbnailAcrossMetricsAndProcesses() throws {
    let url = URL(fileURLWithPath: "/Applications/Example.app")
    var lookups = 0, loads = 0
    let source = NSImage(size: NSSize(width: 256, height: 256))
    let cache = ProcessIconCache(appURL: { _ in lookups += 1; return url }, loadIcon: { _ in loads += 1; return source })
    let first = EnergyProcessID(pid: 10, started: 1)
    let image = try #require(cache.image(for: first))
    #expect(cache.image(for: first) === image)
    #expect(cache.image(for: EnergyProcessID(pid: 11, started: 2)) === image)
    #expect(lookups == 2 && loads == 1)
    #expect(image.size == NSSize(width: 14, height: 14))
    let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
    #expect(bitmap.pixelsWide == 28 && bitmap.pixelsHigh == 28)
}

@Test @MainActor func missingProcessIconsAreCachedAndReusedPIDIsResolvedAgain() {
    var lookups = 0
    let cache = ProcessIconCache(appURL: { _ in lookups += 1; return nil }, loadIcon: { _ in Issue.record("Unexpected icon load"); return nil })
    let first = EnergyProcessID(pid: 10, started: 1)
    #expect(cache.image(for: first) == nil)
    #expect(cache.image(for: first) == nil)
    #expect(lookups == 1)
    #expect(cache.image(for: EnergyProcessID(pid: 10, started: 2)) == nil)
    #expect(lookups == 2)
}

@Test @MainActor func processIconCacheEvictsOldEntriesAndFindsContainingHelperApp() {
    var lookups = 0
    let cache = ProcessIconCache(capacity: 2, appURL: { _ in lookups += 1; return nil })
    let first = EnergyProcessID(pid: 1, started: 1)
    _ = cache.image(for: first)
    _ = cache.image(for: EnergyProcessID(pid: 2, started: 2))
    _ = cache.image(for: EnergyProcessID(pid: 3, started: 3))
    _ = cache.image(for: first)
    #expect(lookups == 4)
    let helper = URL(fileURLWithPath: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
    #expect(ProcessIconCache.enclosingApplication(helper)?.path == "/Applications/Example.app")
    #expect(ProcessIconCache.enclosingApplication(URL(fileURLWithPath: "/usr/libexec/example")) == nil)
}
