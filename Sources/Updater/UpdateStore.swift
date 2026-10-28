import Foundation

/// Machine-local updater state and on-disk layout. Deliberately separate from
/// SettingsStore/ConfigSync: check timestamps and DMG paths are meaningless
/// across machines and must not ride iCloud sync.
final class UpdateStore {
    static let shared = UpdateStore()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "switchmux.updates."
    private enum Key {
        static let lastCheck = "switchmux.updates.lastCheck"
        static let skipVersion = "switchmux.updates.skipVersion"
        static let pending = "switchmux.updates.pending"
        static let alertedVersion = "switchmux.updates.alertedVersion"
    }

    private init() {
        try? FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
    }

    /// ~/Library/Application Support/SwitchMux/updates/
    var updatesDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwitchMux", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
    }

    func dmgURL(for version: String) -> URL {
        updatesDirectory.appendingPathComponent("SwitchMux-\(version).dmg")
    }

    func newWorkDirectory() throws -> URL {
        let dir = updatesDirectory
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Remove leftover work dirs from previous runs.
    func pruneWorkDirectories() {
        let workRoot = updatesDirectory.appendingPathComponent("work", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: workRoot,
                                                                      includingPropertiesForKeys: nil) {
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Remove downloaded DMGs, optionally keeping one version.
    func deleteDMGs(except keepVersion: String?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: updatesDirectory,
                                                                         includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "dmg" {
            if let keepVersion, entry.lastPathComponent == "SwitchMux-\(keepVersion).dmg" { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: UserDefaults state

    var lastCheck: Date? {
        get { defaults.object(forKey: Key.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastCheck) }
    }

    var skipVersion: String? {
        get { defaults.string(forKey: Key.skipVersion) }
        set { defaults.set(newValue, forKey: Key.skipVersion) }
    }

    var alertedVersion: String? {
        get { defaults.string(forKey: Key.alertedVersion) }
        set { defaults.set(newValue, forKey: Key.alertedVersion) }
    }

    var pendingUpdate: PendingUpdate? {
        get {
            guard let data = defaults.data(forKey: Key.pending),
                  let pending = try? JSONDecoder().decode(PendingUpdate.self, from: data) else { return nil }
            return pending
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.pending)
            } else {
                defaults.removeObject(forKey: Key.pending)
            }
        }
    }

    /// Returns the persisted pending update only if its DMG is still on disk.
    func validPendingUpdate() -> PendingUpdate? {
        guard let pending = pendingUpdate,
              FileManager.default.fileExists(atPath: pending.dmgPath) else {
            if pendingUpdate != nil { clearPending() }
            return nil
        }
        return pending
    }

    func clearPending() {
        if let pending = pendingUpdate {
            try? FileManager.default.removeItem(at: pending.dmgURL)
        }
        pendingUpdate = nil
    }
}
