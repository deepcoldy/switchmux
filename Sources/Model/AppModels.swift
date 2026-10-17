import Foundation

/// App source mode of a profile: Dock / Switcher / Custom.
enum AppMode: String, Codable, CaseIterable, Identifiable {
    case dock
    case switcher
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dock: return "Dock"
        case .switcher: return "Switcher"
        case .custom: return "自定义"
        }
    }

    var detail: String {
        switch self {
        case .dock: return "Dock 模式下，显示的应用与 Dock 一致。"
        case .switcher: return "Switcher 模式下，显示的应用与切换器（⌘+Tab）一致。"
        case .custom: return "自定义模式下，可以自由添加应用并设置快捷键。"
        }
    }
}

/// One pinned application in a Custom profile.
struct ProfileAction: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var bundleID: String?
    /// Lower-cased trigger character, e.g. "1" / "q". nil = unbound.
    var character: String?

    init(id: UUID = UUID(), name: String, path: String, bundleID: String? = nil, character: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.character = character
    }
}

/// A configuration profile.
struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var mode: AppMode
    var sortOrder: Int
    var actions: [ProfileAction]
    /// Trigger characters for Dock / Switcher slots.
    var characters: String
    /// Dock mode: show Finder as the first slot.
    var includeFinder: Bool

    init(id: UUID = UUID(), name: String, mode: AppMode, sortOrder: Int,
         actions: [ProfileAction] = [], characters: String = "1234567890", includeFinder: Bool = false) {
        self.id = id
        self.name = name
        self.mode = mode
        self.sortOrder = sortOrder
        self.actions = actions
        self.characters = characters
        self.includeFinder = includeFinder
    }
}

/// Per-app silent rule.
struct SilentEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var bundleID: String
    var name: String
    /// Don't show the App Bar while this app is frontmost.
    var hideBar: Bool
    /// Ignore trigger shortcuts while this app is frontmost.
    var disableShortcuts: Bool

    init(id: UUID = UUID(), bundleID: String, name: String, hideBar: Bool = true, disableShortcuts: Bool = false) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.hideBar = hideBar
        self.disableShortcuts = disableShortcuts
    }
}

enum BarVerticalPosition: String, Codable, CaseIterable {
    case top, middle, bottom
    var label: String {
        switch self {
        case .top: return "顶部"
        case .middle: return "中间"
        case .bottom: return "底部"
        }
    }
}

enum BarHorizontalPosition: String, Codable, CaseIterable {
    case left, center, right
    var label: String {
        switch self {
        case .left: return "左侧"
        case .center: return "居中"
        case .right: return "右侧"
        }
    }
}

/// Scope of the window thumbnail switcher.
enum WindowScope: String, Codable, CaseIterable, Identifiable {
    case allWindows
    case currentApp
    case currentSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allWindows: return "所有窗口"
        case .currentApp: return "当前应用的窗口"
        case .currentSpace: return "当前 Space 的窗口"
        }
    }
}
