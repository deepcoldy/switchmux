import AppKit

/// Reads the user's persistent Dock applications.
enum DockReader {
    struct DockApp {
        let url: URL
        let name: String
        let bundleID: String?
    }

    static func apps() -> [DockApp] {
        let plistURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let items = plist["persistent-apps"] as? [[String: Any]] else {
            return []
        }
        var result: [DockApp] = []
        for item in items {
            guard let tileData = item["tile-data"] as? [String: Any] else { continue }
            var resolved: URL?
            if let fileData = tileData["file-data"] as? [String: Any],
               let raw = fileData["_CFURLString"] as? String {
                if raw.hasPrefix("file://") {
                    resolved = URL(string: raw)
                } else {
                    resolved = URL(fileURLWithPath: raw)
                }
            }
            if resolved == nil, let label = tileData["file-label"] as? String {
                resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: label)
            }
            guard let url = resolved, FileManager.default.fileExists(atPath: url.path) else { continue }
            let name = (tileData["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let bundleID = (tileData["bundle-identifier"] as? String) ?? Bundle(url: url)?.bundleIdentifier
            result.append(DockApp(url: url, name: name, bundleID: bundleID))
        }
        return result
    }

    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
}
