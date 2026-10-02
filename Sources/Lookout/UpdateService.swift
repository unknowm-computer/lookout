import AppKit
import Combine
import LookoutCore
import Sparkle

@MainActor final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var status = "업데이트 배포 준비 중입니다."
    let configuration: UpdateConfiguration?
    let version: String
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    private var waitingForResult = false
    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 버전"
        var issue: String?
        do {
            configuration = try UpdateConfiguration.validate(
                feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
            )
        } catch { configuration = nil; issue = error.localizedDescription }
        super.init()
        if let issue { status = issue }
    }
    /// Defer until SwiftUI has finished launching; CLI probes never start the updater.
    func start() {
        guard configuration != nil, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        // Background checks may discover versions; downloads and installation require a user action.
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            Task { @MainActor in self?.canCheck = value }
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            Task { @MainActor in self?.automaticChecks = value }
        }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] value in
            Task { @MainActor in self?.lastCheck = value }
        }.store(in: &subscriptions)
        do {
            try updater.start()
            status = "새 버전을 확인할 수 있습니다."
        } catch {
            status = "업데이트 시작 실패: \(error.localizedDescription)"
            canCheck = false
        }
    }
    func check() {
        guard configuration != nil else { return }
        start()
        guard canCheck, let controller else { return }
        waitingForResult = true
        status = "새 버전을 확인하는 중입니다."
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) {
        guard configuration != nil else { return }
        start()
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        waitingForResult = false
        status = "새 버전 \(item.displayVersionString)을 사용할 수 있습니다."
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        waitingForResult = false
        // Sparkle explains incompatible OS / skipped versions in its standard result window.
        status = "설치할 새 업데이트가 없습니다."
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        waitingForResult = false
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain, failure.code == SUError.noUpdateError.rawValue { return }
        if failure.domain == SUSparkleErrorDomain, failure.code == SUError.installationCanceledError.rawValue {
            status = "업데이트 설치를 취소했습니다."
            return
        }
        status = "업데이트 확인 실패: \(error.localizedDescription)"
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if waitingForResult, error == nil { status = "새 버전을 확인할 수 있습니다." }
        waitingForResult = false
    }
}
