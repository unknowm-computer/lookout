import AppKit
import FanControlProtocol
import ServiceManagement
import LookoutCore
import SwiftUI
import UserNotifications

@main struct LookoutEntryPoint {
    @MainActor static func main() async {
        // Freeze the language before settings can be edited during this launch.
        _ = L10n.language
        if CommandLine.arguments.contains("--notification-status") {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings()
            print("Authorization \(status.authorizationStatus.rawValue) · alerts \(status.alertSetting.rawValue) · sound \(status.soundSetting.rawValue)")
            let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix("lookout.") }
            for notification in delivered {
                print("\(notification.request.identifier) · \(notification.request.content.title) · \(notification.request.content.body)")
            }
            print("Delivered Lookout notifications: \(delivered.count)")
            return
        }
        if CommandLine.arguments.contains("--fan-helper-refresh") {
            let service = SMAppService.daemon(plistName: FanControlEndpoint.plist)
            do {
                if service.status != .notRegistered {
                    try await service.unregister()
                    // ServiceManagement can reject immediate re-registration even after its completion.
                    try await Task.sleep(for: .seconds(2))
                }
                try service.register()
                UserDefaults.standard.set(try FanPeerIdentity.requirement(for: Bundle.main.bundleURL), forKey: "fanHelperRevision.v1")
                print("Fan helper registration: \(service.status.rawValue)")
            } catch { print("Fan helper registration failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--fan-control-restore") {
            let control = CoolingControlService()
            control.refresh()
            print("Restore helper registration: \(control.registration.rawValue)")
            control.select(.system)
            while control.busy { try? await Task.sleep(for: .milliseconds(100)) }
            let value = try? CoolingCollector().sample(force: true)
            let confirmed = value?.fans.count == 2 && value?.fans.allSatisfy { $0.automatic == true } == true
            print("Fan restore hardware confirmed: \(confirmed) · \(control.message ?? "no service error")")
            control.stop()
            return
        }
        if CommandLine.arguments.contains("--fan-control-test") {
            let collector = CoolingCollector()
            let control = CoolingControlService()
            do {
                let before = try collector.sample(force: true)
                guard before.canControl, before.fans.allSatisfy({ $0.automatic == true }) else {
                    print("Fan test refused: hardware unavailable or another controller is active")
                    return
                }
                func report(_ stage: String, _ value: CoolingReading) {
                    print("\(stage): \(value.temperature.map(ValueFormat.temperature) ?? "—") · " + value.fans.map {
                        "fan\($0.id) \(ValueFormat.rpm($0.rpm)) target \($0.target.map(ValueFormat.rpm) ?? "—") auto=\($0.automatic == true)"
                    }.joined(separator: " · "))
                    fflush(stdout)
                }
                report("before", before)
                control.select(.comfortable)
                while control.busy { try await Task.sleep(for: .milliseconds(100)) }
                guard control.appliedMode == .comfortable else {
                    print("Apply failed: \(control.message ?? "unknown")"); control.stop(); return
                }
                for _ in 0..<4 {
                    let value = try collector.sample(force: true)
                    control.pulse(reading: value, enabled: true)
                    report("comfortable", value)
                    try await Task.sleep(for: .seconds(3))
                }
                control.select(.system)
                while control.busy { try await Task.sleep(for: .milliseconds(100)) }
                let after = try collector.sample(force: true)
                report("restored", after)
                print("Restoration confirmed: \(after.fans.allSatisfy { $0.automatic == true })")
                control.stop()
            } catch { control.stop(); print("Fan test failed: \(error)") }
            return
        }
        if CommandLine.arguments.contains("--cooling-probe") {
            let collector = CoolingCollector()
            for _ in 0..<3 {
                do {
                    let value = try collector.sample(force: true)
                    print("CPU \(value.cpu.map(ValueFormat.temperature) ?? "—") · GPU \(value.gpu.map(ValueFormat.temperature) ?? "—") · \(value.band.title) · control \(value.canControl)")
                    for fan in value.fans { print("Fan \(fan.id): \(ValueFormat.rpm(fan.rpm)) · \(Int(fan.minimum))–\(Int(fan.maximum)) RPM · automatic \(fan.automatic == true)") }
                } catch { print("Cooling unavailable: \(error)") }
                try? await Task.sleep(for: .seconds(5))
            }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            let sampler = MetricSampler()
            for _ in 0..<3 {
                for reading in await sampler.collect(MonitorConfiguration()) {
                    switch reading.value {
                    case .cooling(let value): print("Cooling CPU \(value.cpu.map(ValueFormat.temperature) ?? "—") GPU \(value.gpu.map(ValueFormat.temperature) ?? "—") · fans \(value.fans.map { ValueFormat.rpm($0.rpm) }.joined(separator: ", "))")
                    case .cpu(let value): print("CPU \(ValueFormat.percent(value))")
                    case .memory(let value):
                        print("Memory \(ValueFormat.memory(value.used)) / \(ValueFormat.memory(value.total)) · \(ValueFormat.percent(value.percent)) · swap \(value.swap.map(ValueFormat.memory) ?? "—") / \(value.swapTotal.map(ValueFormat.memory) ?? "—")")
                    case .network(let value): print("Network \(value.interface) ↓\(ValueFormat.rate(value.download)) ↑\(ValueFormat.rate(value.upload))")
                    case .disk(let value):
                        print("Disk R \(value.activity.map { ValueFormat.rate($0.read) } ?? "—") W \(value.activity.map { ValueFormat.rate($0.write) } ?? "—") · \(value.activityMessage ?? "")")
                    case .storage(let capacity):
                        print("Storage \(ValueFormat.storage(capacity.used)) / \(ValueFormat.storage(capacity.total)) · available \(ValueFormat.storage(capacity.available))")
                    case .power(let value):
                        print("Energy process estimate \(value.watts.map(ValueFormat.watts) ?? "—") · \(value.measuredCount)/\(value.totalCount) processes · sleep preventers \(value.sleepPreventers.map { String($0.count) } ?? "—") · \(value.message ?? "")")
                    case .gpu(let value): print("GPU \(value.name) \(ValueFormat.percent(value.utilization)) · renderer \(value.renderer.map(ValueFormat.percent) ?? "—") · tiler \(value.tiler.map(ValueFormat.percent) ?? "—") · shared \(value.sharedMemory.map(ValueFormat.memory) ?? "—")")
                    case nil: print("\(reading.metric.title): \(reading.message ?? "—")")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
            return
        }
        LookoutApp.main()
    }
}

@MainActor struct LookoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let services = AppServices.shared
    var body: some Scene {
        Window("Lookout", id: "preview") {
            PreviewPanelContent(services: services)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--panel") ? .presented : .suppressed)
        .commands {
            CommandMenu(L10n.text("모니터링")) {
                Button(L10n.text("메뉴바 패널 열기")) { services.menuBar.showPanel() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button(L10n.text("설정…")) { services.menuBar.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct PreviewPanelContent: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        MonitorPanel(monitor: services.monitor, settings: services.settings,
                     notifications: services.monitor.notifications,
                     onOpenSettings: {
                         dismiss()
                         services.menuBar.showSettings()
                     }, onClose: { dismiss() })
    }
}

@MainActor final class AppServices {
    static let shared = AppServices()
    let settings: SettingsStore
    let monitor: MonitoringCoordinator
    let updates = UpdateService()
    lazy var menuBar = MenuBarController(settings: settings, monitor: monitor, updates: updates)
    private init() {
        settings = SettingsStore()
        monitor = MonitoringCoordinator(settings: settings)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The status item keeps monitoring available even when every window is closed.
        false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppServices.shared.menuBar.showSettings() }
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppServices.shared.menuBar.start()
        AppServices.shared.updates.start()
        if CommandLine.arguments.contains("--settings") { AppServices.shared.menuBar.showSettings() }
        if CommandLine.arguments.contains("--panel") { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.menuBar.stop()
        AppServices.shared.monitor.stop()
    }
}
