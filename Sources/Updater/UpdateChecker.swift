import AppKit
import Combine
import ServiceManagement

/// Orchestrates update checks, downloads, verification, the ready prompt and
/// install/relaunch. Drives the 更新 pane and status-bar menu via @Published.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastCheck: Date?
    @Published private(set) var skipVersion: String?

    private let store = UpdateStore.shared
    private var timer: Timer?
    private var launchWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var installing = false

    private init() {}

    // MARK: Lifecycle

    func start() {
        lastCheck = store.lastCheck
        skipVersion = store.skipVersion
        reconcileAfterLaunch()
        observeWake()

        SettingsStore.shared.$autoUpdateCheck
            .dropFirst()   // current value is handled explicitly below
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled { self?.armSchedule() } else { self?.disarm() }
            }
            .store(in: &cancellables)
        if SettingsStore.shared.autoUpdateCheck { armSchedule() }
    }

    /// After a relaunch: clear a consumed pending, re-arm login item, prune.
    func reconcileAfterLaunch() {
        store.pruneWorkDirectories()
        if let pending = store.validPendingUpdate() {
            // Same version now installed => the swap succeeded on a prior launch.
            if pending.version == AppInfo.shortVersion {
                store.clearPending()
                store.alertedVersion = nil
                if SettingsStore.shared.launchAtLogin {
                    try? SMAppService.mainApp.register()
                }
                state = .idle
            } else {
                state = .ready(pending)
            }
        }
    }

    // MARK: Scheduling

    private func armSchedule() {
        disarm()
        let forceNow = ProcessInfo.processInfo.environment["SWITCHMUX_UPDATE_CHECK_NOW"] != nil
        let interval: TimeInterval = 24 * 60 * 60

        // Launch check: randomized delay when due; force-now runs immediately.
        if forceNow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkNow(mode: .automatic)
            }
        } else if let last = lastCheck, Date().timeIntervalSince(last) < interval {
            let delay = interval - Date().timeIntervalSince(last) + TimeInterval.random(in: 0...1800)
            let work = DispatchWorkItem { [weak self] in self?.checkNow(mode: .automatic) }
            launchWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.checkNow(mode: .automatic) }
            launchWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval.random(in: 20...900),
                                          execute: work)
        }

        // Recurring daily tick (the launch item above covers the first run).
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow(mode: .automatic)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func disarm() {
        launchWorkItem?.cancel()
        launchWorkItem = nil
        timer?.invalidate()
        timer = nil
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, SettingsStore.shared.autoUpdateCheck else { return }
                if let last = self.store.lastCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
                self.checkNow(mode: .automatic)
            }
    }

    // MARK: Check

    func checkNow(mode: UpdateCheckMode) {
        guard !state.isBusy, !installing else { return }
        if case .ready = state { return }   // a pending update takes precedence
        state = .checking

        GitHubClient.shared.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.lastCheck = Date()
                self.lastCheck = self.store.lastCheck
                switch result {
                case .failure(let error):
                    if mode == .manual {
                        self.state = .error(error.userMessage)
                    } else {
                        NSLog("SwitchMuxUpdater: automatic check failed: \(error)")
                        // A pending ready state would have skipped the check;
                        // nothing transient to preserve here.
                        self.state = .idle
                    }
                case .success(let release):
                    guard let info = release.makeReleaseInfo() else {
                        // No valid newer stable DMG: treat as up to date.
                        if self.releaseIsCurrentOrOlder(release) {
                            self.state = .upToDate
                        } else if mode == .manual {
                            // Draft/prerelease/malformed: explicit manual check
                            // still reports "latest" rather than an error.
                            self.state = .upToDate
                        } else {
                            self.state = .idle
                        }
                        return
                    }
                    guard self.skipVersion != info.version.description else {
                        if mode == .manual { self.state = .upToDate }
                        else { self.state = .idle }
                        return
                    }
                    // A pending update already downloaded beats a fresh offer.
                    if let pending = self.store.validPendingUpdate() {
                        self.state = .ready(pending)
                        return
                    }
                    self.state = .available(info)
                    if mode == .automatic {
                        // NWPathMonitor blocks briefly on its first update, so
                        // probe off the main thread.
                        DispatchQueue.global(qos: .utility).async {
                            let metered = UpdateDownloader.isMetered()
                            DispatchQueue.main.async {
                                guard case .available = self.state else { return }
                                if metered {
                                    NSLog("SwitchMuxUpdater: metered network, skipping auto-download")
                                } else {
                                    self.startDownload(info)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func releaseIsCurrentOrOlder(_ release: GitHubRelease) -> Bool {
        guard let v = SemVer.parse(tag: release.tagName) else { return false }
        return v <= AppInfo.currentVersion
    }

    // MARK: Download + verify

    func startDownload(_ release: ReleaseInfo? = nil) {
        guard !UpdateDownloader.shared.isDownloading else { return }
        let info: ReleaseInfo
        if let release { info = release }
        else if case .available(let r) = state { info = r }
        else { return }

        state = .downloading(info, 0)
        let destination = store.dmgURL(for: info.version.description)
        UpdateDownloader.shared.download(info, to: destination, progress: { [weak self] fraction in
            DispatchQueue.main.async { self?.state = .downloading(info, fraction) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.state = .error(error.userMessage)
                case .success:
                    self.state = .verifying(info)
                    self.finishDownload(info, dmg: destination)
                }
            }
        })
    }

    private func finishDownload(_ info: ReleaseInfo, dmg: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Checksum first: a wrong/broken file never becomes "pending".
            guard UpdateVerifier.verifyDMGChecksum(dmg, expected: info.sha256) else {
                try? FileManager.default.removeItem(at: dmg)
                DispatchQueue.main.async { self.state = .error(UpdateError.checksumMismatch.userMessage) }
                return
            }
            let pending = PendingUpdate(
                version: info.version.description,
                dmgPath: dmg.path,
                releaseNotes: info.releaseNotes,
                pageURL: info.pageURL,
                downloadedAt: Date()
            )
            self.store.deleteDMGs(except: pending.version)
            self.store.pendingUpdate = pending
            DispatchQueue.main.async {
                self.state = .ready(pending)
                self.announceReady(pending)
            }
        }
    }

    func skipCurrentVersion() {
        if case .ready(let pending) = state {
            store.skipVersion = pending.version
            skipVersion = pending.version
            store.clearPending()
            state = .idle
        } else if let info = state.release {
            store.skipVersion = info.version.description
            skipVersion = info.version.description
            state = .idle
        }
    }

    // MARK: Ready prompt

    private func announceReady(_ pending: PendingUpdate) {
        HotkeyController.shared.showToast("SwitchMux \(pending.version) 已准备好，重启后安装")
        guard store.alertedVersion != pending.version else { return }
        store.alertedVersion = pending.version

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "SwitchMux 更新已就绪"
        alert.informativeText = "版本 \(pending.version) 已下载并校验完成。退出并立即安装？"
        alert.addButton(withTitle: "重启并安装")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            installPending()
        }
    }

    // MARK: Install

    func installPending() {
        guard !installing, case .ready(let pending) = state else { return }
        guard AppInfo.canReplaceInPlace() else {
            state = .error(UpdateError.readOnlyLocation.userMessage)
            NSWorkspace.shared.open(AppInfo.releasesWebURL)
            return
        }
        installing = true
        UpdateInstaller.attach(pending.dmgURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let message):
                    self.installing = false
                    self.state = .error(message)
                case .mounted(let app, let mountPoint, let workDir):
                    // codesign --verify inside commitAndRelaunch is synchronous.
                    DispatchQueue.global(qos: .userInitiated).async {
                        UpdateInstaller.commitAndRelaunch(
                            app: app, mountPoint: mountPoint, workDir: workDir, pending: pending
                        ) { success, message in
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                guard success else {
                                    self.installing = false
                                    UpdateInstaller.detach(mountPoint)
                                    self.state = .error(message)
                                    if message.contains("ad-hoc") || message.contains("开发版") {
                                        NSWorkspace.shared.open(AppInfo.releasesWebURL)
                                    }
                                    return
                                }
                                // The detached script waits for our exit; terminate now.
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppInfo.releasesWebURL)
    }
}
