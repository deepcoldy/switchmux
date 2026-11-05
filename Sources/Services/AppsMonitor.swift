import AppKit
import Combine

/// Tracks running applications / frontmost app / MRU order and resolves the
/// App Bar tiles from the configured app list.
final class AppsMonitor {
    static let shared = AppsMonitor()

    /// Fires on the main thread when apps launch / quit / activate / hide.
    let changePublisher = PassthroughSubject<Void, Never>()

    private var observers: [NSObjectProtocol] = []
    private let iconCache = NSCache<NSString, NSImage>()

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bid = app.bundleIdentifier, app.activationPolicy == .regular {
                    SettingsStore.shared.noteActivated(bid)
                }
                self?.changePublisher.send()
            })
        }
        // Seed MRU with whatever is frontmost right now.
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            SettingsStore.shared.noteActivated(bid)
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

    func runningApp(for entry: (url: URL, bundleID: String?)) -> NSRunningApplication? {
        let apps = regularApps
        let target = entry.url.standardizedFileURL
        if let byURL = apps.first(where: { $0.bundleURL?.standardizedFileURL == target }) { return byURL }
        guard let bid = entry.bundleID else { return nil }
        return apps.first { $0.bundleIdentifier == bid }
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    // MARK: Slots
    func slots() -> [Slot] {
        let apps = regularApps
        let front = frontmost
        return SettingsStore.shared.apps.map { entry in
            let url = entry.url
            let target = url.standardizedFileURL
            let running = apps.first(where: { $0.bundleURL?.standardizedFileURL == target })
                ?? entry.bundleID.flatMap { bid in apps.first { $0.bundleIdentifier == bid } }
            return Slot(
                key: entry.id.uuidString,
                displayName: entry.name,
                bundleID: entry.bundleID,
                url: url,
                character: entry.character,
                keyCode: entry.triggerKeyCode,
                running: running != nil,
                active: running != nil && running?.processIdentifier == front?.processIdentifier,
                hidden: running?.isHidden ?? false,
                icon: icon(for: url)
            )
        }
    }
}
