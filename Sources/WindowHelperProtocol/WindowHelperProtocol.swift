import Foundation
import WindowLayoutModel

public enum WindowHelperEndpoint {
    public static let name = "local.lookout.window-helper"
    public static let plist = name + ".plist"
    public static let bundleName = "LookoutWindowHelper.app"
    public static let version = 1
    public static let maximumTransferBytes = 4_194_304
}

@objc public protocol WindowHelperProtocol {
    func configure(_ enabled: Bool, legacy: Data?, reply: @escaping @Sendable (Data?) -> Void)
    func status(reply: @escaping @Sendable (Data?) -> Void)
    func perform(_ action: String, reply: @escaping @Sendable (Data?) -> Void)
}
@objc public protocol WindowHelperEvents {
    func stateChanged(_ data: Data)
}

public enum WindowLayoutCaptureInterval: Int, CaseIterable, Codable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    public static let defaultValue: Self = .oneMinute
    public var duration: Duration { .seconds(rawValue) }
}

/// Settings passed through the existing configuration argument. Snapshots remain owned by the helper.
public struct WindowHelperConfiguration: Codable, Sendable {
    public let captureInterval: WindowLayoutCaptureInterval

    public init(captureInterval: WindowLayoutCaptureInterval) {
        self.captureInterval = captureInterval
    }

    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 256 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct WindowHelperState: Codable, Sendable {
    public var version = WindowHelperEndpoint.version
    public var enabled: Bool
    public var busy: Bool
    public var phase: WindowLayoutPhase
    public var permission: WindowAccessReport
    public var savedAt: Date?
    /// Last successful periodic in-memory capture during this session, even after it is saved to disk.
    public var lastRecentCaptureAt: Date?
    public var backupAt: Date?
    public var pending: Bool
    public var processID: Int32
    public var restoreReport: WindowRestoreReport?
    public var savedWithOmissions: Bool?
    public var previewEnabled: Bool?
    public var screenRecordingAllowed: Bool?
    public var previewAt: Date?
    public var backupPreviewAt: Date?
    public init(enabled: Bool, busy: Bool, phase: WindowLayoutPhase, permission: WindowAccessReport,
                savedAt: Date?, backupAt: Date?, pending: Bool, processID: Int32, restoreReport: WindowRestoreReport? = nil,
                savedWithOmissions: Bool? = nil) {
        self.enabled = enabled; self.busy = busy; self.phase = phase; self.permission = permission
        self.savedAt = savedAt; self.backupAt = backupAt; self.pending = pending; self.processID = processID
        self.restoreReport = restoreReport
        self.savedWithOmissions = savedWithOmissions
    }
    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count < 65_536, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == WindowHelperEndpoint.version, value.processID > 0,
              value.restoreReport?.isValid != false else { return nil }
        return value
    }
}

/// Only the old locally stored snapshots are accepted. No caller-supplied paths or arbitrary AX commands.
public struct WindowLayoutTransfer: Codable, Sendable {
    public var current: Data?
    public var backup: Data?
    public var pending: Bool
    public var restoreRequested: Bool
    public init(current: Data?, backup: Data?, pending: Bool, restoreRequested: Bool) {
        self.current = current; self.backup = backup; self.pending = pending; self.restoreRequested = restoreRequested
    }
    public var validCurrent: WindowLayoutSnapshot? { WindowLayoutSnapshot.decode(current) }
    public var validBackup: WindowLayoutSnapshot? { WindowLayoutSnapshot.decode(backup) }
    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= WindowHelperEndpoint.maximumTransferBytes else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
