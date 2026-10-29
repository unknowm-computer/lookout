import AppKit
import WindowLayoutRuntime

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let server = WindowHelperServer()
do {
    try server.start()
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler { server.stop(); exit(0) }
    termination.resume()
    application.run()
    withExtendedLifetime(termination) {}
} catch {
    fputs("Lookout window helper could not start.\n", stderr)
    exit(1)
}
