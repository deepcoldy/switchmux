import AppKit
import Combine
import CryptoKit
import SystemConfiguration

/// File-backed settings store. Default location is the user's iCloud Drive
/// folder (`~/Library/Mobile Documents/com~apple~CloudDocs/SwitchMux`), which a
/// non-sandboxed app can read/write without any entitlement and which macOS
/// syncs across the user's machines. Locally (`~/Library/Application
/// Support/SwitchMux`) it keeps:
/// - `config.json`: this Mac's current settings (works offline / without iCloud);
/// - `config.base.json`: the iCloud state this Mac last incorporated, the
///   common ancestor for `ConfigMerge`, so a Mac only overrides what it changed;
/// - `conflicts/`: copies of iCloud conflict versions taken before resolving them.
///
/// iCloud is never written blindly: a sync makes sure the newest version is
/// downloaded, resolves conflict versions, merges, and writes only if this Mac
/// has changes iCloud lacks — re-checked inside the coordinated write.
///
/// This also makes the config independent of the code signature / binary name,
/// so ad-hoc rebuilds (and the unbundled debug executable) never lose it.
final class ConfigSync: NSObject, ObservableObject {
    static let shared = ConfigSync()

    enum Phase: Equatable {
        case localOnly
        case idle
        case syncing
        case waiting(String)
        case failed(String)
    }

    enum Outcome {
        /// Newer settings from iCloud were applied.
        case updated
        /// This Mac's changes were written to iCloud.
        case uploaded
        case upToDate
        /// Nothing new, but iCloud couldn't be made to download the file again
        /// (local changes not uploaded yet, or eviction refused).
        case notRedownloaded
        case unavailable(String)

        var message: String {
            switch self {
            case .updated: return "已从 iCloud 获取最新配置"
            case .uploaded: return "已把本机的修改同步到 iCloud"
            case .upToDate: return "配置已是最新"
            case .notRedownloaded: return "本机的 iCloud 副本已是最新，但 iCloud 暂时无法重新下载，可稍后再试"
            case .unavailable(let reason): return reason
            }
        }
    }

    struct EditInfo: Equatable {
        var date: Date
        var device: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastEdit: EditInfo?
    /// Set when the iCloud copy was last written by an older SwitchMux (which
    /// still rewrites it on every switch): the name of that Mac, if known.
    @Published private(set) var olderBuildWriter: String?

    /// Main queue, after changes from iCloud were merged into the local state.
    var onChange: (() -> Void)?
    /// Main queue, right before local state is read for a merge, so edits still
    /// waiting for their save debounce are included.
    var flushPendingEdits: (() -> Void)?
    /// Keys the app changes on its own (e.g. after the welcome window): changing
    /// them doesn't turn a first-run seed into a real config.
    var seedNeutralKeys: Set<String> = []
    /// Keys written as a function of another key (derived → source): an edit
    /// dates them only together with their source, since older builds rewrite
    /// them in another form without any edit (`profiles` without `keyCode`).
    var derivedKeys: [String: String] = [:]

    private let directoryName = "SwitchMux"
    private let fileName = "config.json"
    private let deviceName: String
    private let io = DispatchQueue(label: "dev.shenhan.switchmux.config-sync", qos: .utility)
    private let presenterQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    /// The presenter's URL must be readable from any thread, so it is fixed at launch.
    private let presentedDirectory: URL?

    // Main-queue state
    private var localData: Data?
    private var baseData: Data?
    private var loaded = false
    private var started = false
    private var attached = false
    private var syncing = false
    private var syncAgain = false
    private var forceAgain = false
    private var activeAgain = false
    private var changedStreak = 0
    /// An earlier pass of a sync re-run for the same callers (after another
    /// Mac wrote in between) already applied changes from iCloud.
    private var appliedBeforeRetry = false
    private var runningCompletions: [(Outcome) -> Void] = []
    private var queuedCompletions: [(Outcome) -> Void] = []
    private var triggerWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var lastFingerprint: String?
    private var holdPassiveUntil: Date?
    private var missingSince: Date?
    private var lastCloudWrite: Date?
    private var cleanedTempFiles = false

    /// An empty iCloud folder is not filled right away: on a new Mac (or after
    /// iCloud Drive was toggled) the existing config may not be listed yet.
    private static let missingGracePeriod: TimeInterval = 120
    private static let pollInterval: TimeInterval = 60

    private override init() {
        let env = ProcessInfo.processInfo.environment
        let local = env["SWITCHMUX_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        overrideDirectory = local
        // Only together with SWITCHMUX_CONFIG_DIR, so a test cloud folder can
        // never be merged into the real local config.
        overrideCloudDirectory = local == nil ? nil
            : env["SWITCHMUX_CLOUD_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        deviceName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        presentedDirectory = Self.cloudDirectory(override: overrideCloudDirectory, local: local,
                                                 name: directoryName, requireICloudDrive: false)
        super.init()
    }

    // MARK: Locations

    /// SWITCHMUX_CONFIG_DIR redirects the local files (smoke tests, dev builds)
    /// and turns iCloud off so they never touch the user's real synced config.
    /// SWITCHMUX_CLOUD_DIR then stands in for the iCloud folder (tests).
    private let overrideDirectory: URL?
    private let overrideCloudDirectory: URL?

    private static func cloudDirectory(override: URL?, local: URL?, name: String,
                                       requireICloudDrive: Bool = true) -> URL? {
        if let override { return override }
        if local != nil { return nil }
        let docs = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        // Missing until the user enables iCloud Drive.
        if requireICloudDrive, !FileManager.default.fileExists(atPath: docs.path) { return nil }
        return docs.appendingPathComponent(name)
    }

    private var cloudURL: URL? {
        Self.cloudDirectory(override: overrideCloudDirectory, local: overrideDirectory, name: directoryName)?
            .appendingPathComponent(fileName)
    }

    /// The real iCloud Drive folder (not a test stand-in): download state,
    /// eviction and conflict versions apply.
    private var managedByICloud: Bool { overrideCloudDirectory == nil }

    private var localDirectory: URL {
        if let overrideDirectory { return overrideDirectory }
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName)
    }

    private var mirrorURL: URL { localDirectory.appendingPathComponent(fileName) }
    private var baseURL: URL { localDirectory.appendingPathComponent("config.base.json") }
    var backupDirectory: URL { localDirectory.appendingPathComponent("conflicts") }

    /// Per-Mac usage files live next to the config (see `UsageStore`).
    var usageDirectory: URL? { cloudURL?.deletingLastPathComponent().appendingPathComponent("usage") }
    var localUsageURL: URL { localDirectory.appendingPathComponent("usage.json") }

    var usesICloud: Bool { cloudURL != nil }

    var locationDescription: String {
        if overrideDirectory != nil { return "自定义目录（SWITCHMUX_CONFIG_DIR）" }
        return usesICloud ? "iCloud 云盘（自动多设备同步）" : "本地（未检测到 iCloud Drive）"
    }

    // MARK: Load / save

    /// This Mac's current settings. Reads local files only (never waits for
    /// iCloud); the first sync, right after launch, merges in iCloud's copy.
    func load<T: Decodable>(_ type: T.Type) -> T? {
        if !loaded { loadInitial() }
        guard let localData else { return nil }
        return try? JSONDecoder().decode(T.self, from: localData)
    }

    /// `edit: false` for changes the app derives on its own (migrating an older
    /// format, defaults for new keys): they keep their previous edit times, so
    /// they never override an actual edit from another Mac.
    func save<T: Encodable>(_ value: T, edit: Bool = true) {
        guard let encoded = try? JSONEncoder().encode(value), let fields = Self.json(encoded) else { return }
        let previous = Self.json(localData)
        // Keys this build doesn't know (from newer builds) are kept.
        let next = (previous ?? [:]).merging(fields) { _, new in new }
        let changed = ConfigMerge.changedKeys(from: previous, to: next)
        guard !changed.isEmpty else { return }
        var stamp = ConfigMerge.Stamp(previous) ?? ConfigMerge.Stamp(baseline: 0)
        if edit {
            let edited = changed.filter { derivedKeys[$0].map(changed.contains) ?? true }
            let now = Date().timeIntervalSince1970
            for key in edited { stamp.times[key] = now }
            if !edited.isEmpty { stamp.editedBy = deviceName }
            if stamp.seeded, !edited.subtracting(seedNeutralKeys).isEmpty { stamp.seeded = false }
        }
        setLocal(ConfigMerge.stamped(next, stamp))
        requestSync(passive: false)
    }

    /// First run on this Mac with no config anywhere: `value` (built from the
    /// Dock) is used until iCloud has a real config, which then wins.
    func seed<T: Encodable>(_ value: T) {
        guard let encoded = try? JSONEncoder().encode(value), let json = Self.json(encoded) else { return }
        setLocal(ConfigMerge.stamped(json, ConfigMerge.Stamp(baseline: 0, editedBy: deviceName, seeded: true)))
        // No common ancestor yet: the first merge goes by edit time, so keys the
        // user changes here win and the untouched seed (time 0) loses, including
        // keys an older build's iCloud file lacks (`apps`, derived from `profiles`).
        baseData = nil
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func loadInitial() {
        loaded = true
        baseData = Self.readSnapshot(baseURL)?.data
        guard let mirror = Self.readSnapshot(mirrorURL), var json = mirror.json else { return }
        localData = mirror.data
        if ConfigMerge.Stamp(json) == nil {
            // Written by an older build, which rewrote it on every switch and
            // loaded iCloud's copy first: its date says nothing about edits,
            // so the first sync takes iCloud's values wherever they differ.
            json = ConfigMerge.stamped(json, ConfigMerge.Stamp(baseline: 0))
        }
        setLocal(json)
    }

    /// Stores `json` as this Mac's state. Returns whether settings changed.
    @discardableResult
    private func setLocal(_ json: ConfigMerge.JSON) -> Bool {
        guard let data = Self.encode(json), data != localData else { return false }
        let changed = !ConfigMerge.sameContent(Self.json(localData), json)
        localData = data
        Self.writeLocal(data, to: mirrorURL)
        if let stamp = ConfigMerge.Stamp(json), !stamp.seeded, stamp.editedAt > 0 {
            lastEdit = EditInfo(date: Date(timeIntervalSince1970: stamp.editedAt), device: stamp.editedBy)
        }
        return changed
    }

    private func setBase(_ data: Data) {
        // A seed as common ancestor would make keys an older build's file
        // lacks (`apps`) look unchanged, so its own list would never apply.
        guard data != baseData, ConfigMerge.Stamp(Self.json(data))?.seeded != true else { return }
        baseData = data
        Self.writeLocal(data, to: baseURL)
    }

    // MARK: Sync

    /// Starts watching iCloud for changes from other Macs and syncs once.
    func start() {
        guard !started else { return }
        started = true
        guard presentedDirectory != nil else { phase = .localOnly; return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // The network usually needs a moment after wake.
                self?.requestSync(after: 5, passive: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.requestSync(passive: false) }
            }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.attached else { return }
                NSFileCoordinator.removeFilePresenter(self)
            }
        attachCloud()
    }

    /// Starts watching the iCloud folder and syncs, as soon as iCloud Drive is
    /// on (also when the user turns it on while SwitchMux runs).
    private func attachCloud() {
        guard !attached else { return }
        guard usesICloud else {
            if phase != .localOnly { phase = .localOnly }
            return
        }
        attached = true
        NSFileCoordinator.addFilePresenter(self)
        startDirectoryWatch()
        requestSync(after: 1, passive: false)
    }

    /// Fetches the newest config from iCloud even if this Mac believes it is
    /// current (evicts the local copy and downloads it again), resolves
    /// conflicts, merges and reports what happened.
    func refreshFromCloud(completion: @escaping (Outcome) -> Void) {
        sync(force: true, passive: false, completion: completion)
    }

    /// Debounced automatic sync. Passive triggers (file events, polling) back
    /// off while iCloud is unavailable; local edits and wake don't.
    func requestSync(after delay: TimeInterval = 0.5, passive: Bool = true) {
        guard usesICloud else { return }
        var delay = delay
        if passive, let hold = holdPassiveUntil { delay = max(delay, hold.timeIntervalSinceNow) }
        triggerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(passive: passive) }
        triggerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sync(force: Bool = false, passive: Bool = true, completion: ((Outcome) -> Void)? = nil) {
        if syncing {
            if let completion { queuedCompletions.append(completion) }
            syncAgain = true
            forceAgain = forceAgain || force
            activeAgain = activeAgain || !passive
            return
        }
        if let completion { runningCompletions.append(completion) }
        syncing = true
        guard let url = cloudURL else {
            phase = .localOnly
            finish(.unavailable("没有使用 iCloud 云盘，配置只保存在本机"))
            return
        }
        triggerWork?.cancel()
        retryWork?.cancel()
        if force || phase != .idle { phase = .syncing }
        flushPendingEdits?()
        let cleanTempFiles = !cleanedTempFiles || force
        cleanedTempFiles = true
        let recentlyWrote = lastCloudWrite.map { Date().timeIntervalSince($0) < 30 } ?? false
        io.async { [self] in
            if cleanTempFiles { removeLeakedTempFiles(in: url.deletingLastPathComponent()) }
            let fetched = fetch(url, force: force, evict: !recentlyWrote)
            DispatchQueue.main.async { self.integrate(fetched, url: url, forced: force) }
        }
    }

    private func integrate(_ fetched: Fetch, url: URL, forced: Bool) {
        let remote: Snapshot?
        switch fetched {
        case .notReady(let reason):
            fail(.waiting(reason), retryAfter: 15)
            return
        case .failed(let reason):
            fail(.failed(reason), retryAfter: 60)
            return
        case .missing:
            remote = nil
            if missingSince == nil { missingSince = Date() }
        case .found(let snapshot):
            remote = snapshot
            missingSince = nil
        }
        holdPassiveUntil = nil

        // Edits made while the fetch ran are merged right here.
        let wasQueued = syncAgain
        flushPendingEdits?()
        if !wasQueued { syncAgain = false }

        let base = Self.json(baseData)
        guard let merged = ConfigMerge.merge(base: base, local: Self.json(localData),
                                             remote: remote?.json, remoteFileTime: remote?.fileTime ?? 0)
        else {
            phase = .idle
            finish(.upToDate)
            return
        }
        // Whatever iCloud had is now part of the local state. Keys an older
        // build dropped count as unchanged, so they stay in the base too.
        let effectiveRemote = remote?.json.map { Self.overlay($0, on: base) }
        if let remote, let effectiveRemote, let data = Self.encode(effectiveRemote) {
            setBase(data)
            // An unstamped file is only news if an older build changed it
            // since (it rewrites the file on every switch while it runs).
            if ConfigMerge.Stamp(remote.json) != nil {
                olderBuildWriter = nil
            } else if !ConfigMerge.sameContent(effectiveRemote, base ?? Self.json(localData)) {
                olderBuildWriter = remote.writer ?? "未知设备"
            }
        }
        let changedLocally = setLocal(merged)
        if changedLocally { onChange?() }
        let applied = changedLocally || appliedBeforeRetry

        if let remote, let effectiveRemote, ConfigMerge.sameContent(effectiveRemote, merged) {
            let unchanged: Outcome = forced && !remote.redownloaded ? .notRedownloaded : .upToDate
            succeed(applied ? .updated : unchanged, fingerprint: remote.fingerprint)
            return
        }
        if remote == nil, let since = missingSince,
           Date().timeIntervalSince(since) < Self.missingGracePeriod {
            let reason = "iCloud 中还没有配置，稍后上传本机配置"
            phase = .waiting(reason)
            scheduleRetry(after: Self.missingGracePeriod - Date().timeIntervalSince(since) + 1)
            finish(applied ? .updated : .unavailable(reason))
            return
        }

        var stamp = ConfigMerge.Stamp(merged) ?? ConfigMerge.Stamp(baseline: 0)
        stamp.savedAt = Date().timeIntervalSince1970
        stamp.savedBy = deviceName
        guard let data = Self.encode(ConfigMerge.stamped(merged, stamp)) else {
            fail(.failed("配置编码失败"), retryAfter: 60)
            return
        }
        let expected = remote?.data
        io.async { [self] in
            let result = writeCloud(data, to: url, expected: expected)
            let fingerprint = Self.fingerprint(url)
            DispatchQueue.main.async {
                switch result {
                case .written:
                    self.setBase(data)
                    self.lastCloudWrite = Date()
                    self.olderBuildWriter = nil
                    self.succeed(applied ? .updated : .uploaded, fingerprint: fingerprint)
                case .changed where self.changedStreak < 3:
                    // Another Mac wrote between our read and write: merge again.
                    self.changedStreak += 1
                    self.appliedBeforeRetry = applied
                    self.finish(nil)
                case .changed:
                    self.fail(.waiting("iCloud 中的配置正在变化，稍后重试"), retryAfter: 30)
                case .failed(let reason):
                    self.fail(.failed(reason), retryAfter: 60)
                }
            }
        }
    }

    private func succeed(_ outcome: Outcome, fingerprint: String?) {
        changedStreak = 0
        lastFingerprint = fingerprint
        lastSynced = Date()
        phase = .idle
        finish(outcome)
    }

    private func fail(_ phase: Phase, retryAfter delay: TimeInterval) {
        changedStreak = 0
        self.phase = phase
        lastFingerprint = nil
        holdPassiveUntil = Date().addingTimeInterval(delay)
        // File events that arrived meanwhile don't need an immediate rerun.
        if !forceAgain && !activeAgain && queuedCompletions.isEmpty { syncAgain = false }
        scheduleRetry(after: delay)
        switch phase {
        case .waiting(let reason), .failed(let reason): finish(.unavailable(reason))
        default: finish(.unavailable("同步失败"))
        }
    }

    /// `nil` re-runs the sync for the same callers.
    private func finish(_ outcome: Outcome?) {
        syncing = false
        var done = runningCompletions
        runningCompletions = []
        if outcome == nil {
            queuedCompletions.insert(contentsOf: done, at: 0)
            done = []
            syncAgain = true
        }
        if let outcome {
            appliedBeforeRetry = false
            done.forEach { $0(outcome) }
        }
        guard syncAgain else { return }
        let force = forceAgain
        syncAgain = false
        forceAgain = false
        activeAgain = false
        runningCompletions = queuedCompletions
        queuedCompletions = []
        sync(force: force, passive: false)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(passive: false) }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Change detection

    /// Safety net for missed notifications: cheap stat, sync only on change.
    private func poll() {
        attachCloud()
        guard attached, let url = cloudURL, !syncing else { return }
        if directorySource == nil { startDirectoryWatch() }
        io.async { [self] in
            let fingerprint = Self.fingerprint(url)
            DispatchQueue.main.async {
                if fingerprint != self.lastFingerprint { self.requestSync() }
            }
        }
    }

    /// Re-armed whenever the folder is deleted or renamed (or didn't exist yet).
    private func startDirectoryWatch() {
        guard directorySource == nil, let dir = cloudURL?.deletingLastPathComponent() else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                self.directorySource = nil
            }
            self.requestSync()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    // MARK: iCloud I/O (io queue)

    private struct Snapshot {
        var data: Data
        /// nil if the file isn't valid JSON.
        var json: ConfigMerge.JSON?
        var fileTime: Double
        var fingerprint: String?
        /// Mac that saved the iCloud version, for files from older builds.
        var writer: String?
        /// A forced fetch made iCloud download the file again.
        var redownloaded = false
    }

    private enum Fetch {
        case missing
        case found(Snapshot)
        case notReady(String)
        case failed(String)
    }

    private enum WriteResult {
        case written, changed, failed(String)
    }

    /// `force`: make iCloud check the server even if it believes the local
    /// copy is current; `evict` allows doing that by downloading it again.
    private func fetch(_ url: URL, force: Bool, evict: Bool) -> Fetch {
        let fm = FileManager.default
        // macOS 13 represents an evicted file by a hidden `.name.icloud` stub.
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).icloud")
        let exists = fm.fileExists(atPath: url.path)
        guard exists || fm.fileExists(atPath: placeholder.path) else { return .missing }

        var redownloaded = !managedByICloud
        if managedByICloud {
            // Downloading again is the only way to make iCloud fetch the
            // server's version when it believes the local copy is current.
            // Only once everything local has been uploaded.
            if force, evict, exists, Self.canEvict(url) {
                do {
                    try fm.evictUbiquitousItem(at: url)
                    redownloaded = !Self.isCurrent(url)
                } catch {
                    NSLog("SwitchMux: evicting config failed: \(error)")
                }
            }
            if force, !redownloaded { try? fm.startDownloadingUbiquitousItem(at: url) }
            if !Self.isCurrent(url) {
                do {
                    try fm.startDownloadingUbiquitousItem(at: url)
                } catch {
                    return .notReady("无法从 iCloud 下载配置：\(error.localizedDescription)")
                }
                guard Self.waitUntilCurrent(url, timeout: force ? 20 : 5) else {
                    return .notReady("正在等待 iCloud 下载最新配置…")
                }
                redownloaded = true
            }
            resolveConflicts(at: url)
        }

        var snapshot: Snapshot?
        var readError: Error?
        let coordinationError = coordinate(timeout: 15) { coordinator, error in
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { url in
                do { snapshot = try Self.readSnapshotOrThrow(url) } catch { readError = error }
            }
        }
        guard var snapshot else {
            if !fm.fileExists(atPath: url.path) { return .missing }
            let error = coordinationError ?? readError
            return .failed("读取 iCloud 配置失败：\(error?.localizedDescription ?? "未知错误")")
        }
        if snapshot.json == nil { backUp(snapshot.data, date: Date(), device: "unreadable") }
        if managedByICloud, ConfigMerge.Stamp(snapshot.json) == nil {
            snapshot.writer = NSFileVersion.currentVersionOfItem(at: url)?.localizedNameOfSavingComputer
        }
        snapshot.fingerprint = Self.fingerprint(url)
        snapshot.redownloaded = redownloaded
        return .found(snapshot)
    }

    /// iCloud keeps concurrent writes as conflict versions and picks an
    /// arbitrary one as current. Combine them by edit time instead, keep
    /// copies, and resolve exactly the versions that were read.
    private func resolveConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty,
              let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
        var versions: [(json: ConfigMerge.JSON, fileTime: Double)] = []
        var read: [NSFileVersion] = []
        var currentData: Data?
        for version in [current] + conflicts {
            guard let data = try? Data(contentsOf: version.url) else { continue }
            let date = version.modificationDate ?? .distantPast
            backUp(data, date: date, device: version.localizedNameOfSavingComputer ?? "unknown")
            if version === current { currentData = data } else { read.append(version) }
            if let json = Self.json(data) { versions.append((json, date.timeIntervalSince1970)) }
        }
        guard !read.isEmpty, let currentData, let resolved = ConfigMerge.resolve(versions) else { return }
        var stamp = ConfigMerge.Stamp(resolved) ?? ConfigMerge.Stamp(baseline: 0)
        stamp.savedAt = Date().timeIntervalSince1970
        stamp.savedBy = deviceName
        let data = Self.encode(ConfigMerge.stamped(resolved, stamp))

        let coordinationError = coordinate(timeout: 15) { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
                // Written meanwhile: the next sync resolves against that.
                guard (try? Data(contentsOf: url)) == currentData else { return }
                if let data, !ConfigMerge.sameContent(resolved, Self.json(currentData)) {
                    do { try data.write(to: url, options: .atomic) } catch {
                        NSLog("SwitchMux: writing resolved config failed: \(error)")
                        return
                    }
                }
                for version in read {
                    version.isResolved = true
                    try? version.remove()
                }
            }
        }
        if let coordinationError { NSLog("SwitchMux: resolving conflicts failed: \(coordinationError)") }
    }

    /// Writes only if the file still holds `expected` (nil: doesn't exist), so
    /// a change that landed after our read is merged instead of overwritten.
    private func writeCloud(_ data: Data, to url: URL, expected: Data?) -> WriteResult {
        var result = WriteResult.failed("写入 iCloud 失败")
        let coordinationError = coordinate(timeout: 15) { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
                let fm = FileManager.default
                let current = fm.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
                guard current == expected else { result = .changed; return }
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    result = .written
                } catch {
                    result = .failed("写入 iCloud 失败：\(error.localizedDescription)")
                }
            }
        }
        if let coordinationError { result = .failed("写入 iCloud 失败：\(coordinationError.localizedDescription)") }
        if case .failed(let reason) = result { NSLog("SwitchMux: \(reason)") }
        return result
    }

    /// Runs a coordinated read or write that gives up after `timeout`, so a
    /// stuck iCloud can't block the I/O queue forever.
    private func coordinate(timeout: TimeInterval,
                            _ body: (NSFileCoordinator, inout NSError?) -> Void) -> NSError? {
        let coordinator = NSFileCoordinator(filePresenter: self)
        let watchdog = DispatchWorkItem { coordinator.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        var error: NSError?
        body(coordinator, &error)
        return error
    }

    /// Older builds wrote `.config.json.tmp-*` next to the config and leaked
    /// them whenever the replace failed; iCloud then copies them to every Mac.
    private func removeLeakedTempFiles(in directory: URL) {
        let fm = FileManager.default
        let prefix = ".\(fileName).tmp-"
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(prefix) {
            let url = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private func backUp(_ data: Data, date: Date, device: String) {
        let fm = FileManager.default
        let dir = backupDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard !existing.contains(where: { $0.hasSuffix("-\(hash).json") }) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let safeDevice = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = "\(formatter.string(from: date))-\(safeDevice)-\(hash).json"
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        let keep = 60
        let all = (existing + [name]).filter { $0.hasSuffix(".json") }.sorted()
        for old in all.prefix(max(0, all.count - keep)) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    // MARK: Helpers

    private static func resourceValues(_ url: URL) -> URLResourceValues? {
        // A queue has no run loop to flush NSURL's resource value cache.
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
        ])
    }

    private static func isCurrent(_ url: URL) -> Bool {
        resourceValues(url)?.ubiquitousItemDownloadingStatus == .current
    }

    private static func canEvict(_ url: URL) -> Bool {
        guard let values = resourceValues(url) else { return false }
        return values.ubiquitousItemDownloadingStatus == .current
            && values.ubiquitousItemIsUploaded == true
            && values.ubiquitousItemIsUploading != true
            && values.ubiquitousItemHasUnresolvedConflicts != true
    }

    private static func waitUntilCurrent(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isCurrent(url) {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    private static func fingerprint(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let values = resourceValues(url)
        return [
            "\(info.st_ino)", "\(info.st_size)",
            "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
            values?.ubiquitousItemDownloadingStatus?.rawValue ?? "-",
            values?.ubiquitousItemHasUnresolvedConflicts == true ? "conflicts" : "-",
        ].joined(separator: "|")
    }

    private static func readSnapshot(_ url: URL) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? readSnapshotOrThrow(url)
    }

    private static func readSnapshotOrThrow(_ url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return Snapshot(data: data, json: json(data), fileTime: modified)
    }

    private static func overlay(_ json: ConfigMerge.JSON, on base: ConfigMerge.JSON?) -> ConfigMerge.JSON {
        guard let base else { return json }
        return json.merging(base) { current, _ in current }
    }

    private static func json(_ data: Data?) -> ConfigMerge.JSON? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? ConfigMerge.JSON
    }

    private static func encode(_ json: ConfigMerge.JSON) -> Data? {
        try? JSONSerialization.data(withJSONObject: json,
                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func writeLocal(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("SwitchMux: config write failed \(url.path): \(error)")
        }
    }
}

// MARK: NSFilePresenter

/// Coordinated writes by iCloud (and other processes) to the SwitchMux folder.
/// Callbacks never block: they only schedule a sync on the main queue.
extension ConfigSync: NSFilePresenter {
    var presentedItemURL: URL? { presentedDirectory }
    var presentedItemOperationQueue: OperationQueue { presenterQueue }

    private func presenterEvent(_ url: URL?) {
        if let url, url.lastPathComponent != fileName { return }
        DispatchQueue.main.async { self.requestSync() }
    }

    func presentedItemDidChange() { presenterEvent(nil) }
    func presentedSubitemDidChange(at url: URL) { presenterEvent(url) }
    func presentedSubitemDidAppear(at url: URL) { presenterEvent(url) }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { presenterEvent(url) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        presenterEvent(url)
    }
}
