import Foundation

/// File-backed settings store. Default location is the user's iCloud Drive
/// folder (`~/Library/Mobile Documents/com~apple~CloudDocs/SwitchMux`), which a
/// non-sandboxed app can read/write without any entitlement and which macOS
/// syncs across the user's machines automatically. A local mirror is always
/// kept in `~/Library/Application Support/SwitchMux` as an offline fallback.
///
/// This also makes the config independent of the code signature / binary name,
/// so ad-hoc rebuilds (and the unbundled debug executable) never lose it.
final class ConfigSync {
    static let shared = ConfigSync()

    var onChange: (() -> Void)?

    private let directoryName = "SwitchMux"
    private let fileName = "config.json"

    private var source: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    private var saving = false
    private var lastData: Data?

    private var home: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    /// iCloud Drive folder (may not exist if the user never enabled iCloud Drive).
    private var iCloudDirectory: URL? {
        let url = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .appendingPathComponent(directoryName)
        return FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) ? url : nil
    }

    private var localDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName)
    }

    private var primaryURL: URL {
        iCloudDirectory?.appendingPathComponent(fileName)
            ?? localDirectory.appendingPathComponent(fileName)
    }

    private var mirrorURL: URL {
        localDirectory.appendingPathComponent(fileName)
    }

    var locationDescription: String {
        iCloudDirectory != nil ? "iCloud 云盘（自动多设备同步）" : "本地（未检测到 iCloud Drive）"
    }

    // MARK: Load / save
    func load<T: Decodable>(_ type: T.Type) -> T? {
        let fm = FileManager.default
        let candidates = [primaryURL, mirrorURL]
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let value = try? JSONDecoder().decode(T.self, from: data) {
                lastData = data
                return value
            }
        }
        return nil
    }

    func save<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        guard data != lastData else { return }
        saving = true
        lastData = data
        let fm = FileManager.default

        func write(_ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString.prefix(8))")
            do {
                try data.write(to: tmp, options: .atomic)
                _ = try? fm.replaceItemAt(url, withItemAt: tmp)
                if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            } catch {
                NSLog("SwitchMux: config write failed \(url.path): \(error)")
            }
        }

        write(primaryURL)
        // Keep the local mirror in sync unless primary IS the local file.
        if primaryURL.path != mirrorURL.path { write(mirrorURL) }

        saving = false
        watch()
    }

    // MARK: Live reload from another device / process
    func watch() {
        if source == nil { startWatch(primaryURL, parent: false) { [weak self] in self?.externalChange() } }
        if parentSource == nil { startWatch(primaryURL.deletingLastPathComponent(), parent: true) { [weak self] in
            self?.externalChange()
        } }
    }

    private func startWatch(_ url: URL, parent: Bool, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: handler)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        if parent { parentSource = src } else { source = src }
    }

    private func externalChange() {
        guard !saving else { return }
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: primaryURL), data != lastData else { return }
        lastData = data
        onChange?()
    }
}
