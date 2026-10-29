import AppKit
import Darwin

/// LaunchServices does not provide a launchDate for every app (including Finder).
/// Use the kernel's process start time as a stable fallback, never the current time or PID alone.
@MainActor enum WindowProcessIdentity {
    static func launchDate(for app: NSRunningApplication) -> Date? {
        resolve(processID: app.processIdentifier, launchDate: app.launchDate)
    }

    static func resolve(processID: Int32, launchDate: Date?,
                        readKernelStart: (Int32) -> Date? = kernelStartDate) -> Date? {
        guard processID > 0 else { return nil }
        // Preserve the identity of existing snapshots that used LaunchServices dates.
        if let launchDate { return launchDate.timeIntervalSince1970.isFinite ? launchDate : nil }
        return readKernelStart(processID)
    }

    nonisolated static func kernelStartDate(_ processID: Int32) -> Date? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(processID), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}
