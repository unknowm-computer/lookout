import AppKit
import LookoutCore
import SwiftUI
import UserNotifications

@main struct LookoutEntryPoint {
    @MainActor static func main() async {
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
        if CommandLine.arguments.contains("--probe") {
            let sampler = MetricSampler()
            for _ in 0..<3 {
                for reading in await sampler.collect(MonitorConfiguration()) {
                    switch reading.value {
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
            MonitorPanel(monitor: services.monitor, settings: services.settings,
                         notifications: services.monitor.notifications,
                         onOpenSettings: { services.menuBar.showSettings() })
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--panel") ? .presented : .suppressed)
        .commands {
            CommandMenu("모니터링") {
                Button("메뉴바 패널 열기") { services.menuBar.showPanel() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("설정…") { services.menuBar.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
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
