import AppKit
import Combine
import LookoutCore
import UserNotifications

@MainActor final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var bannersEnabled = false
    @Published private(set) var busy = false
    @Published private(set) var feedback: String?
    @Published private(set) var panelRequest: UUID?
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private var active: [UUID: AlertEvent] = [:]
    private var eligible: Set<UUID> = []
    private var delivered: Set<UUID>
    private var sending: Set<UUID> = []
    private var retryAfter: [UUID: TimeInterval] = [:]
    private var sound = false
    var canNotify: Bool {
        (authorization == .authorized || authorization == .provisional) && bannersEnabled
    }
    var permissionDescription: String {
        switch authorization {
        case .notDetermined: L10n.text("알림을 켤 때 macOS 권한을 요청합니다.")
        case .denied: L10n.text("알림 권한이 꺼져 있습니다. 시스템 설정 → 알림 → Lookout에서 허용하세요.")
        case .authorized, .provisional:
            bannersEnabled ? L10n.text("macOS 알림 사용 가능") : L10n.text("배너가 꺼져 있습니다. 시스템 설정 → 알림 → Lookout에서 변경하세요.")
        default: L10n.text("macOS 알림 설정을 확인하세요.")
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        delivered = Set((defaults.stringArray(forKey: "deliveredAlertIDs.v1") ?? []).compactMap(UUID.init(uuidString:)))
        super.init()
        center.delegate = self
        Task { await refreshAuthorization() }
    }
    func refreshAuthorization() async {
        updateAuthorization(await center.notificationSettings()); flush()
    }
    func requestAuthorization() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound]); feedback = nil
        } catch { feedback = L10n.text("알림 권한 요청 실패: \(error.localizedDescription)") }
        await refreshAuthorization()
    }
    func test(sound: Bool) async {
        if authorization == .notDetermined { await requestAuthorization() }
        await refreshAuthorization()
        guard canNotify else { feedback = permissionDescription; return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Lookout 테스트 알림")
        content.body = L10n.text("알림 연결을 확인합니다. 실제 경고가 아닙니다. 클릭하면 상세 패널이 열립니다.")
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: "lookout.test.\(UUID().uuidString)", content: content, trigger: nil))
            feedback = L10n.text("테스트 알림을 요청했습니다. 표시는 macOS 알림·집중 모드 설정을 따릅니다.")
        } catch { feedback = L10n.text("테스트 알림 요청 실패: \(error.localizedDescription)") }
    }
    func synchronize(active events: [AlertEvent], sound: Bool, eligible: Set<UUID>) {
        let next = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let removed = Set(active.keys).subtracting(next.keys)
        center.removePendingNotificationRequests(withIdentifiers: removed.map { identifier($0) })
        active = next; self.sound = sound; self.eligible = eligible.intersection(next.keys)
        let before = delivered
        delivered.formIntersection(next.keys)
        retryAfter = retryAfter.filter { next[$0.key] != nil }
        if before != delivered { persistDelivered() }
        flush()
    }
    private func flush() {
        guard canNotify else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for event in active.values where eligible.contains(event.id) && !delivered.contains(event.id) && !sending.contains(event.id) && now >= retryAfter[event.id, default: 0] {
            sending.insert(event.id)
            Task { [weak self] in await self?.send(event) }
        }
    }
    private func send(_ event: AlertEvent) async {
        defer { sending.remove(event.id) }
        updateAuthorization(await center.notificationSettings())
        guard canNotify, eligible.contains(event.id), active[event.id] != nil else { return }
        // Cover a restart between system acceptance and saving our delivery receipt.
        let existing = await center.deliveredNotifications()
        guard eligible.contains(event.id), active[event.id] != nil else { return }
        if existing.contains(where: { $0.request.identifier == identifier(event.id) }) {
            delivered.insert(event.id); persistDelivered(); return
        }
        let content = UNMutableNotificationContent()
        content.title = "Lookout · \(event.title)"
        content.body = event.message
        content.threadIdentifier = "lookout.\(event.metric.rawValue)"
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier(event.id), content: content, trigger: nil))
            guard active[event.id] != nil else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier(event.id)])
                center.removeDeliveredNotifications(withIdentifiers: [identifier(event.id)])
                return
            }
            delivered.insert(event.id); persistDelivered(); retryAfter.removeValue(forKey: event.id)
        } catch {
            retryAfter[event.id] = ProcessInfo.processInfo.systemUptime + 30
            feedback = L10n.text("경고 알림 요청 실패: \(error.localizedDescription)")
        }
    }
    private func updateAuthorization(_ settings: UNNotificationSettings) {
        authorization = settings.authorizationStatus; bannersEnabled = settings.alertSetting == .enabled
    }
    private func identifier(_ id: UUID) -> String { "lookout.alert.\(id.uuidString)" }
    private func persistDelivered() { defaults.set(delivered.map(\.uuidString), forKey: "deliveredAlertIDs.v1") }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in
                self?.panelRequest = UUID()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
