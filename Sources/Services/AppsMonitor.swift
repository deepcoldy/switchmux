import AppKit
import Combine

/// Tracks running applications, frontmost app and most-recently-used order,
/// and resolves the slot list for the active profile.
final class AppsMonitor {
    static let shared = AppsMonitor()

    let changePublisher = PassthroughSubject<Void, Never>()

    private var observers: [NSObjectProtocol] = []
    private let iconCache = NSCache<NSString, NSImage>()

    private init() {
        let ws = NSWorkspace.shared
        let center = ws.notificationCenter
        let noteNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in noteNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bid = app.bundleIdentifier, app.activationPolicy == .regular {
                    SettingsStore.shared.recordActivation(bid)
                }
                self?.changePublisher.send()
            })
        }
    }

    // MARK: Running app queries
    var regularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    var frontmost: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func runningApp(forBundleID bid: String?) -> NSRunningApplication? {
        guard let bid else { return nil }
        return regularApps.first { $0.bundleIdentifier == bid }
    }

    func runningApp(forURL url: URL) -> NSRunningApplication? {
        regularApps.first { app in
            guard let appURL = app.bundleURL else { return false }
            return appURL.standardizedFileURL == url.standardizedFileURL
        }
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size: CGFloat = 128
        icon.size = NSSize(width: size, height: size)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    // MARK: MRU order for Switcher mode
    private func mruRunningApps() -> [NSRunningApplication] {
        let apps = regularApps
        let byID = Dictionary(grouping: apps, by: { $0.bundleIdentifier ?? "" })
        var ordered: [NSRunningApplication] = []
        var seen = Set<String>()
        for bid in SettingsStore.shared.mruBundleIDs {
            if let app = byID[bid]?.first, seen.insert(bid).inserted {
                ordered.append(app)
            }
        }
        // Apps launched before SwitchMux tracked them: append by launch date, then name.
        let rest = apps.filter { app in
            guard let bid = app.bundleIdentifier else { return true }
            return !seen.contains(bid)
        }.sorted { a, b in
            let da = a.launchDate ?? .distantPast
            let db = b.launchDate ?? .distantPast
            if da != db { return da > db }
            return (a.localizedName ?? "") < (b.localizedName ?? "")
        }
        ordered.append(contentsOf: rest)
        return ordered
    }

    // MARK: Slot resolution
    func slots(for profile: Profile) -> [Slot] {
        switch profile.mode {
        case .dock: return dockSlots(profile)
        case .switcher: return switcherSlots(profile)
        case .custom: return customSlots(profile)
        }
    }

    private func makeSlot(url: URL, name: String, bundleID: String?, character: String?, keyPrefix: String) -> Slot {
        let running = self.runningApp(forURL: url) ?? runningApp(forBundleID: bundleID)
        let frontID = frontmost?.bundleIdentifier
        return Slot(
            key: keyPrefix + (bundleID ?? url.path),
            displayName: name,
            bundleID: bundleID,
            url: url,
            character: character,
            running: running != nil,
            active: bundleID != nil && frontID == bundleID,
            hidden: running?.isHidden ?? false,
            icon: icon(for: url)
        )
    }

    private func dockSlots(_ profile: Profile) -> [Slot] {
        var entries: [(URL, String, String?)] = []
        if profile.includeFinder {
            entries.append((DockReader.finderURL, "Finder", "com.apple.finder"))
        }
        for app in DockReader.apps() {
            entries.append((app.url, app.name, app.bundleID))
        }
        let chars = Array(profile.characters)
        return entries.enumerated().map { idx, entry in
            let ch = idx < chars.count ? String(chars[idx]).lowercased() : nil
            return makeSlot(url: entry.0, name: entry.1, bundleID: entry.2, character: ch, keyPrefix: "dock:")
        }
    }

    private func switcherSlots(_ profile: Profile) -> [Slot] {
        let filter = Set(SettingsStore.shared.switcherFilter)
        let chars = Array(profile.characters)
        return mruRunningApps().enumerated().compactMap { idx, app -> Slot? in
            guard let url = app.bundleURL else { return nil }
            if let bid = app.bundleIdentifier, filter.contains(bid) { return nil }
            let ch = idx < chars.count ? String(chars[idx]).lowercased() : nil
            return makeSlot(
                url: url,
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier,
                character: ch,
                keyPrefix: "switcher:"
            )
        }
    }

    private func customSlots(_ profile: Profile) -> [Slot] {
        profile.actions.map { action in
            let url = URL(fileURLWithPath: action.path)
            return makeSlot(
                url: url,
                name: action.name,
                bundleID: action.bundleID,
                character: action.character?.lowercased(),
                keyPrefix: "custom:\(action.id.uuidString):"
            )
        }
    }
}
