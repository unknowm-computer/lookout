import AppKit
import Darwin
import Testing
@testable import WindowLayoutRuntime

@Test @MainActor func missingLaunchServicesDateUsesTheSameKernelIdentityForSaveAndRestore() {
    let started = Date(timeIntervalSince1970: 1_700_000_000.123456)
    var reads: [Int32] = []
    let read: (Int32) -> Date? = { pid in reads.append(pid); return started }
    let saved = WindowProcessIdentity.resolve(processID: 123, launchDate: nil, readKernelStart: read)
    let restored = WindowProcessIdentity.resolve(processID: 123, launchDate: nil, readKernelStart: read)
    #expect(saved == started && restored == saved)
    #expect(reads == [123, 123])
    let reusedPID = WindowProcessIdentity.resolve(processID: 123, launchDate: nil,
                                                 readKernelStart: { _ in started.addingTimeInterval(1) })
    #expect(reusedPID != saved)
}

@Test @MainActor func existingLaunchServicesIdentityIsPreservedWithoutAKernelRead() {
    let existing = Date(timeIntervalSince1970: 1_700_000_000)
    var reads = 0
    let date = WindowProcessIdentity.resolve(processID: 123, launchDate: existing,
                                             readKernelStart: { _ in reads += 1; return existing.addingTimeInterval(1) })
    #expect(date == existing && reads == 0)
}

@Test @MainActor func unavailableProcessStartDoesNotFabricateAnIdentity() {
    var reads = 0
    #expect(WindowProcessIdentity.resolve(processID: 123, launchDate: nil,
                                          readKernelStart: { _ in reads += 1; return nil }) == nil)
    #expect(reads == 1)
    #expect(WindowProcessIdentity.resolve(processID: 0, launchDate: nil,
                                          readKernelStart: { _ in reads += 1; return Date() }) == nil)
    #expect(reads == 1)
}

@Test @MainActor func kernelStartDateIsStableForTheCurrentProcessAndRejectsInvalidPIDs() {
    let first = WindowProcessIdentity.kernelStartDate(getpid())
    #expect(first != nil && first == WindowProcessIdentity.kernelStartDate(getpid()))
    #expect(first.map { $0 <= Date() } == true)
    #expect(WindowProcessIdentity.kernelStartDate(0) == nil)
    #expect(WindowProcessIdentity.kernelStartDate(-1) == nil)
    #expect(WindowProcessIdentity.kernelStartDate(Int32.max) == nil)
}
