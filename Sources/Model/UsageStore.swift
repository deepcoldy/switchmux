import AppKit
import Combine
import CryptoKit
import IOKit
import SystemConfiguration

/// Switch counts. Each Mac counts into its own file (`usage/<device>.json`
/// next to the iCloud config), so counting never rewrites the shared config
/// and can't conflict. Totals add up every Mac's file plus the counts that
/// builds up to 1.2.1 kept in the config itself (`SettingsStore.usageCount`).
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var total = 0
    @Published private(set) var byDay: [String: Int] = [:]

    private struct Counts: Codable {
        var deviceID: String
        var device: String?
        var count = 0
        var byDay: [String: Int] = [:]
        var updatedAt: Double?
    }

    private var own: Counts
    /// Other Macs' files, by file name.
    private var others: [String: Counts] = [:]
    private var legacyCount = 0
    private var legacyByDay: [String: Int] = [:]
    private var dirty = false
    /// This Mac's file in iCloud hasn't been read yet this launch. It can be
    /// ahead of the local counts (fresh install, local file lost or restored
    /// from an older backup), so it isn't overwritten until it has been read
    /// or found missing.
    private var adopting: Bool
    /// The local counts found at launch, already part of `own`.
    private var launchCounts: Counts?
    private var flushWhenAdopted = false
    private var flushWork: DispatchWorkItem?
    private var localWork: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    private let io = DispatchQueue(label: "dev.shenhan.switchmux.usage", qos: .utility)

    /// Counts reach iCloud at most this often (and on sleep).
    private static let flushInterval: TimeInterval = 10 * 60
    private static let localWriteDelay: TimeInterval = 5

    private init() {
        let stored = (try? Data(contentsOf: ConfigSync.shared.localUsageURL))
            .flatMap { try? JSONDecoder().decode(Counts.self, from: $0) }
        let deviceID = Self.hardwareID() ?? stored?.deviceID ?? UUID().uuidString
        if let stored, stored.deviceID == deviceID {
            own = stored
            launchCounts = stored
        } else {
            // No counts yet, or copied from another Mac by Migration Assistant
            // (that Mac's counts stay in its own file).
            own = Counts(deviceID: deviceID)
        }
        adopting = ConfigSync.shared.usageDirectory != nil
        own.device = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

        let settings = SettingsStore.shared
        settings.$usageCount.combineLatest(settings.$usageByDay)
            .sink { [weak self] count, days in
                self?.legacyCount = count
                self?.legacyByDay = days
                self?.recompute()
            }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.flush()
            }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.flush(toCloud: false)
            }

        // Publish this Mac's file once per launch, then pick up the others.
        dirty = true
        scheduleFlush(after: 10)
        reload()
    }

    /// A switch performed through SwitchMux (App Bar or window switcher).
    func record() {
        let day = SettingsStore.dayFormatter.string(from: Date())
        own.count += 1
        own.byDay[day, default: 0] += 1
        total += 1
        byDay[day, default: 0] += 1
        dirty = true
        scheduleLocalWrite()
        scheduleFlush(after: Self.flushInterval)
    }

    /// Re-reads the other Macs' files (downloading them if needed).
    func reload() {
        guard let dir = ConfigSync.shared.usageDirectory else { return }
        let ownName = "\(own.deviceID).json"
        let adopt = adopting
        io.async { [weak self] in
            let fm = FileManager.default
            var found: [String: Counts] = [:]
            var pending = Set<String>()
            var ownCounts: Counts?
            var ownPending = false
            let entries = try? fm.contentsOfDirectory(atPath: dir.path)
            for entry in entries ?? [] {
                // macOS 13 shows an evicted file as a hidden `.name.icloud` stub.
                var name = entry
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                }
                guard name.hasSuffix(".json"), !name.hasPrefix("."), adopt || name != ownName else { continue }
                let url = dir.appendingPathComponent(name)
                guard Self.download(url) else {
                    if name == ownName { ownPending = true } else { pending.insert(name) }
                    continue
                }
                let counts = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Counts.self, from: $0) }
                if name == ownName { ownCounts = counts } else if let counts { found[name] = counts }
            }
            // Without a usage folder, this Mac's file is only known to be missing
            // once iCloud lists the config next to it.
            if entries == nil {
                let parent = dir.deletingLastPathComponent()
                ownPending = !["config.json", ".config.json.icloud"].contains {
                    fm.fileExists(atPath: parent.appendingPathComponent($0).path)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for name in pending { found[name] = self.others[name] }
                self.others = found
                if adopt, self.adopting, !ownPending { self.finishAdopting(ownCounts) }
                self.recompute()
            }
        }
    }

    /// Adds what this Mac's iCloud file counted beyond the local counts found
    /// at launch (per day), on top of the counts made since.
    private func finishAdopting(_ earlier: Counts?) {
        adopting = false
        if let earlier, earlier.deviceID == own.deviceID {
            for (day, n) in earlier.byDay {
                let extra = n - (launchCounts?.byDay[day] ?? 0)
                guard extra > 0 else { continue }
                own.byDay[day, default: 0] += extra
                own.count += extra
            }
            dirty = true
        }
        launchCounts = nil
        if dirty { scheduleLocalWrite() }
        if flushWhenAdopted {
            flushWhenAdopted = false
            flush()
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleLocalWrite() {
        guard localWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.writeLocal() }
        localWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localWriteDelay, execute: work)
    }

    func flush(toCloud: Bool = true) {
        flushWork?.cancel()
        flushWork = nil
        guard dirty else { return }
        guard !adopting else {
            writeLocal()
            flushWhenAdopted = flushWhenAdopted || toCloud
            reload()
            scheduleFlush(after: 60)
            return
        }
        guard let data = writeLocal(), toCloud else { return }
        dirty = false
        guard let dir = ConfigSync.shared.usageDirectory else { return }
        let url = dir.appendingPathComponent("\(own.deviceID).json")
        io.async { [weak self] in
            var failed = false
            var coordinationError: NSError?
            // Only this Mac writes this file, so there is nothing to merge.
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                           error: &coordinationError) { url in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSLog("SwitchMux: usage upload failed: \(error)")
                    failed = true
                }
            }
            if coordinationError != nil || failed {
                DispatchQueue.main.async { self?.dirty = true }
            }
        }
        reload()
    }

    /// Writes this Mac's counts to the local file; returns what was written.
    @discardableResult
    private func writeLocal() -> Data? {
        localWork?.cancel()
        localWork = nil
        own.updatedAt = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(own) else { return nil }
        let localURL = ConfigSync.shared.localUsageURL
        do {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: localURL, options: .atomic)
        } catch {
            NSLog("SwitchMux: usage write failed: \(error)")
            return nil
        }
        return data
    }

    private func recompute() {
        var days = legacyByDay
        var sum = legacyCount
        for counts in [own] + Array(others.values) {
            sum += counts.count
            for (day, n) in counts.byDay { days[day, default: 0] += n }
        }
        total = sum
        byDay = days
    }

    /// Makes sure the newest version of an iCloud file is local (waits briefly).
    private static func download(_ url: URL) -> Bool {
        let fm = FileManager.default
        func current() -> Bool {
            var url = url
            url.removeAllCachedResourceValues()
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            return status == nil ? fm.fileExists(atPath: url.path) : status == .current
        }
        if current() { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.25)
            if current() { return true }
        }
        return false
    }

    /// Name of this Mac's usage file: stable per Mac and user, and not carried
    /// over by Migration Assistant. Derived from the hardware UUID (hashed, it
    /// ends up in a file name).
    static func hardwareID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                   kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard let uuid else { return nil }
        let digest = SHA256.hash(data: Data("\(uuid):\(getuid())".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
