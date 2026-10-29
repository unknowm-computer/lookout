import Darwin
import FanControlProtocol
import Foundation
import FanSupport
import MachO
import OSLog
import SystemConfiguration

/// All hardware access and ownership changes run on one serial queue.
/// There is no arbitrary command, path, SMC key, temperature or RPM RPC.
final class FanHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.lookout.fan-helper.control", qos: .utility)
    private let collector = CoolingCollector()
    private var policy = CoolingControlPolicy()
    private var timer: DispatchSourceTimer?
    private var mode = CoolingMode.system
    private var lastHeartbeat = 0.0
    private var lastStep = 0.0
    private var lastTargets: [Int: Double] = [:]
    private var error: String?
    private var ownsFans = false
    private var connection: NSXPCConnection?
    private let clientRequirement: String
    private let marker = FanRecoveryMarker()
    init(clientRequirement: String) { self.clientRequirement = clientRequirement }
    func recoverAfterCrash() throws {
        if marker.exists {
            _ = try collector.sample(force: true)
            try collector.restoreSystem()
            try marker.clear()
        }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection client: NSXPCConnection) -> Bool {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil,
              uid != 0, client.effectiveUserIdentifier == uid else { return false }
        let accepted = queue.sync { () -> Bool in
            guard connection == nil else { return false }
            connection = client
            return true
        }
        guard accepted else { return false }
        client.setCodeSigningRequirement(clientRequirement)
        client.exportedInterface = NSXPCInterface(with: FanControlProtocol.self)
        client.exportedObject = Session(helper: self)
        client.invalidationHandler = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.restoreOwnedFans()
                self.connection = nil
                if !self.ownsFans { exit(0) }
            }
        }
        client.interruptionHandler = { client.invalidate() }
        client.resume()
        return true
    }
    func changeMode(_ raw: String, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard let requested = CoolingMode(rawValue: raw) else { reply("invalidMode"); return }
            guard requested != .system else { restoreOwnedFans(); reply(error); return }
            guard CoolingHardware.isM1ProMacBook else { reply("unsupported"); return }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            mode = requested; policy.reset()
            step()
            if error == nil { startTimer() }
            reply(error)
        }
    }
    func heartbeat(reply: @escaping @Sendable (Data?, String?) -> Void) {
        queue.async { [self] in
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            let state = FanControlStatus(mode: mode.rawValue, message: error, targets: lastTargets)
            reply(try? JSONEncoder().encode(state), nil)
        }
    }
    func restore(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            // An explicit authenticated reset also recovers a previous session's delayed write.
            Logger(subsystem: FanControlEndpoint.name, category: "control").info("Explicit automatic restore requested")
            do { if !ownsFans { try marker.create(); ownsFans = true } }
            catch { reply("restoreFailed"); return }
            restoreOwnedFans()
            Logger(subsystem: FanControlEndpoint.name, category: "control").info("Explicit automatic restore finished; ownsFans=\(self.ownsFans)")
            reply(error)
        }
    }
    func shutdown() { queue.sync { restoreOwnedFans() } }
    func exitIfUnused() {
        queue.asyncAfter(deadline: .now() + 10) { [self] in
            if connection == nil && !ownsFans { exit(0) }
        }
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.step() }
        self.timer = timer; timer.resume()
    }
    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        guard CoolingControlPolicy.leaseIsValid(lastHeartbeat: lastHeartbeat, now: now, maximumAge: FanControlEndpoint.leaseSeconds) else {
            restoreOwnedFans(); error = "leaseExpired"; return
        }
        do {
            let reading = try collector.sample(uptime: now, force: true)
            guard let targets = policy.targets(mode: mode, reading: reading, elapsed: lastStep > 0 ? now - lastStep : 3) else {
                throw CoolingError.invalidSensors
            }
            if !ownsFans, reading.fans.contains(where: { $0.automatic == false }) { throw CoolingError.externalController }
            lastStep = now
            if !ownsFans { try marker.create() }
            // Mark ownership before the first write so partial failures always restore both fans.
            ownsFans = true
            if targets != lastTargets || reading.fans.contains(where: { $0.automatic == true }) { try collector.setTargets(targets) }
            lastTargets = targets; error = nil
        } catch {
            Logger(subsystem: FanControlEndpoint.name, category: "control").error("Control failed: \(String(describing: error), privacy: .public)")
            restoreOwnedFans()
            if case CoolingError.externalController = error { self.error = "externalController" }
            else { self.error = self.error ?? "controlFailed" }
        }
    }
    private func restoreOwnedFans() {
        timer?.cancel(); timer = nil
        if ownsFans {
            do { try collector.restoreSystem(); try marker.clear(); ownsFans = false; error = nil }
            catch {
                // Keep ownership and retry restoration; do not silently report automatic mode.
                Logger(subsystem: FanControlEndpoint.name, category: "control").error("Restore failed: \(String(describing: error), privacy: .public)")
                self.error = "restoreFailed"
                let retry = DispatchSource.makeTimerSource(queue: queue)
                retry.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(300))
                retry.setEventHandler { [weak self] in self?.restoreOwnedFans() }
                timer = retry; retry.resume()
            }
        }
        mode = .system; policy.reset(); lastTargets = [:]; lastStep = 0
    }
    private final class Session: NSObject, FanControlProtocol, @unchecked Sendable {
        private let helper: FanHelper
        init(helper: FanHelper) { self.helper = helper }
        func setMode(_ mode: String, reply: @escaping @Sendable (String?) -> Void) {
            let callback = ErrorReply(reply); helper.changeMode(mode) { callback.call($0) }
        }
        func heartbeat(reply: @escaping @Sendable (Data?, String?) -> Void) {
            let callback = StateReply(reply); helper.heartbeat { callback.call($0, $1) }
        }
        func restore(reply: @escaping @Sendable (String?) -> Void) {
            let callback = ErrorReply(reply); helper.restore { callback.call($0) }
        }
    }
    private final class ErrorReply: @unchecked Sendable {
        let block: @Sendable (String?) -> Void
        init(_ block: @escaping @Sendable (String?) -> Void) { self.block = block }
        func call(_ error: String?) { block(error) }
    }
    private final class StateReply: @unchecked Sendable {
        let block: @Sendable (Data?, String?) -> Void
        init(_ block: @escaping @Sendable (Data?, String?) -> Void) { self.block = block }
        func call(_ data: Data?, _ error: String?) { block(data, error) }
    }
}

// The helper derives its only allowed client from its own installed bundle, never an RPC path.
guard geteuid() == 0 else { fputs("Fan helper must be launched by macOS as a daemon.\n", stderr); exit(1) }
// launchd may replace argv[0] with the job label; use dyld's actual executable path.
var pathLength: UInt32 = 0
_ = _NSGetExecutablePath(nil, &pathLength)
var pathBytes = [CChar](repeating: 0, count: Int(pathLength))
guard _NSGetExecutablePath(&pathBytes, &pathLength) == 0 else { exit(0) }
let executable = URL(fileURLWithPath: String(decoding: pathBytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let logger = Logger(subsystem: FanControlEndpoint.name, category: "bootstrap")
// Recovery must still run if the app's signature changed during an update.
do {
    let recovery = FanHelper(clientRequirement: "false")
    try recovery.recoverAfterCrash()
} catch {
    fputs("Automatic fan control recovery failed; launchd will retry.\n", stderr); exit(1)
}
do {
    logger.info("Helper starting from \(executable.path, privacy: .public)")
    let requirement = try FanPeerIdentity.requirement(for: app)
    let helper = FanHelper(clientRequirement: requirement)
    let listener = NSXPCListener(machServiceName: FanControlEndpoint.name)
    listener.delegate = helper
    // Handle normal launchd termination before the process exits.
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termination.setEventHandler { @Sendable in helper.shutdown(); exit(0) }; termination.resume()
    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interruption.setEventHandler { @Sendable in helper.shutdown(); exit(0) }; interruption.resume()
    listener.resume()
    helper.exitIfUnused()
    RunLoop.current.run()
} catch {
    logger.error("Client signature check failed for \(app.path, privacy: .public): \(String(describing: error), privacy: .public)")
    fputs("Unable to verify the Lookout client signature.\n", stderr); exit(0)
}

final class FanRecoveryMarker {
    private let path = "/var/run/local.lookout.fan-helper.active"
    var exists: Bool { access(path, F_OK) == 0 }
    func create() throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MarkerError.io }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG else { throw MarkerError.io }
        guard fsync(fd) == 0 else { throw MarkerError.io }
    }
    func clear() throws {
        if unlink(path) != 0 && errno != ENOENT { throw MarkerError.io }
    }
    private enum MarkerError: Error { case io }
}
