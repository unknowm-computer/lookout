import AppKit
@preconcurrency import ApplicationServices
import Combine
import FanControlProtocol
import WindowHelperProtocol

/// A user-session LaunchAgent. Window access never runs in the privileged fan daemon.
@MainActor public final class WindowHelperServer {
    private let engine = WindowLayoutService(startEnabled: false)
    private var subscription: AnyCancellable?
    private var listener: NSXPCListener?
    private var delegate: WindowListenerDelegate?
    private var client: NSXPCConnection?
    public init() {}
    public func start() throws {
        let helper = Bundle.main.bundleURL
        let app = helper.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard helper.lastPathComponent == WindowHelperEndpoint.bundleName,
              Bundle(url: app)?.bundleIdentifier == "local.lookout.app" else { throw ServerError.invalidBundle }
        let delegate = WindowListenerDelegate(server: self, requirement: try FanPeerIdentity.requirement(for: app))
        let listener = NSXPCListener(machServiceName: WindowHelperEndpoint.name)
        listener.delegate = delegate
        self.delegate = delegate; self.listener = listener
        subscription = engine.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.publish() }
        }
        listener.resume()
    }
    fileprivate func attach(_ connection: NSXPCConnection) { client = connection }
    fileprivate func configure(_ enabled: Bool, legacy: Data?) -> Data? {
        // Keep the XPC argument for compatibility, but legacy app snapshots have no boot identity.
        // Importing them here could resurrect a layout cleared after reboot.
        engine.setEnabled(enabled); engine.refresh()
        return encodedState()
    }
    fileprivate func perform(_ action: String) -> Data? {
        switch action {
        case "refresh": engine.refresh()
        case "restore": engine.restoreNow()
        case "previous": engine.restoreNow(previous: true)
        case "baseline": engine.useCurrentLayout()
        case "permission":
            // This only requests the OS prompt. It cannot grant or reset TCC approval.
            engine.refresh()
            if !engine.trusted {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                engine.openAccessibilitySettings()
            }
        default: return nil
        }
        return encodedState()
    }
    fileprivate func encodedState() -> Data? { try? JSONEncoder().encode(engine.report()) }
    private func publish() {
        guard let data = encodedState(), let proxy = client?.remoteObjectProxy as? WindowHelperEvents else { return }
        proxy.stateChanged(data)
    }
    public func stop() { engine.stop(); listener?.invalidate() }
    private enum ServerError: Error { case invalidBundle }
}

private final class WindowListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let server: WindowHelperServer
    private let requirement: String
    private let lock = NSLock()
    private var occupied = false
    init(server: WindowHelperServer, requirement: String) { self.server = server; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        lock.lock()
        guard !occupied else { lock.unlock(); return false }
        occupied = true; lock.unlock()
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: WindowHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: WindowHelperEvents.self)
        connection.exportedObject = WindowHelperSession(server: server)
        connection.invalidationHandler = { [weak self] in
            if let self { self.lock.lock(); self.occupied = false; self.lock.unlock() }
            Task { @MainActor [server = self?.server] in server?.stop(); exit(0) }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        let box = WindowConnectionBox(connection)
        Task { @MainActor [server, box] in server.attach(box.connection) }
        connection.resume()
        return true
    }
}
private final class WindowHelperSession: NSObject, WindowHelperProtocol, @unchecked Sendable {
    private let server: WindowHelperServer
    init(server: WindowHelperServer) { self.server = server }
    func configure(_ enabled: Bool, legacy: Data?, reply: @escaping @Sendable (Data?) -> Void) {
        guard legacy == nil || legacy!.count <= WindowHelperEndpoint.maximumTransferBytes else { reply(nil); return }
        Task { @MainActor [server] in reply(server.configure(enabled, legacy: legacy)) }
    }
    func status(reply: @escaping @Sendable (Data?) -> Void) {
        Task { @MainActor [server] in reply(server.encodedState()) }
    }
    func perform(_ action: String, reply: @escaping @Sendable (Data?) -> Void) {
        Task { @MainActor [server] in reply(server.perform(action)) }
    }
}

/// NSXPCConnection supports configuration/resume from the listener and use on the main actor.
private final class WindowConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}
