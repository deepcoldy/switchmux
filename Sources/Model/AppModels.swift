import AppKit
import Carbon.HIToolbox

/// One application pinned to the App Bar.
struct AppEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var bundleID: String?
    /// Display label of the trigger key, lower-cased ("1", "q", ";"). nil = unbound.
    var character: String?
    /// Physical key code of the trigger. Absent in configs written before 1.2;
    /// resolved from `character` through the US layout then.
    var keyCode: UInt16?

    init(id: UUID = UUID(), name: String, path: String, bundleID: String? = nil,
         character: String? = nil, keyCode: UInt16? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.character = character
        self.keyCode = keyCode ?? character.flatMap { KeyCodes.code(for: $0) }
    }

    /// Key code the event tap matches on.
    var triggerKeyCode: UInt16? {
        keyCode ?? character.flatMap { KeyCodes.code(for: $0) }
    }

    var url: URL { URL(fileURLWithPath: path) }

    static func make(url: URL, character: String? = nil) -> AppEntry {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        return AppEntry(name: name, path: url.path, bundleID: bundle?.bundleIdentifier, character: character)
    }
}

/// US-layout key codes for the characters SwitchMux auto-assigns. Recorded
/// shortcuts store the real key code, so other layouts work as pressed.
enum KeyCodes {
    static let tab: UInt16 = 48
    static let grave: UInt16 = 50        // ` on ANSI (key above Tab)
    static let isoSection: UInt16 = 10   // § on ISO keyboards (key above Tab)
    /// The key above Tab on the keyboard in use.
    static var keyAboveTab: UInt16 {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO ? isoSection : grave
    }
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let space: UInt16 = 49
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    private static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
    private static let reverse: [UInt16: String] = Dictionary(uniqueKeysWithValues: table.map { ($1, $0) })

    /// Character → key code for the user's current keyboard layout (so a
    /// legacy "q" binding on AZERTY lands on the key printed Q). Built once on
    /// first use, which happens on the main thread (TIS requirement).
    private static let layoutTable: [String: UInt16] = buildLayoutTable()

    private static func buildLayoutTable() -> [String: UInt16] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        var result: [String: UInt16] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let str = String(utf16CodeUnits: chars, count: length).lowercased()
                let usable = !str.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
                }
                // Lowest code wins, so the main-row digits beat the keypad.
                if usable && result[str] == nil { result[str] = code }
            }
        }
        return result
    }

    static func code(for character: String) -> UInt16? {
        let c = character.lowercased()
        return layoutTable[c] ?? table[c]
    }
    static func character(for code: UInt16) -> String? { reverse[code] }

    /// Order in which free keys are handed out to newly added apps.
    static let assignmentOrder = Array("1234567890qwertyuiopasdfghjklzxcvbnm").map(String.init)
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

/// Scope of the ⌘Tab window switcher.
enum WindowScope: String, Codable, CaseIterable, Identifiable {
    case allWindows
    case currentSpace
    case currentApp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allWindows: return "所有窗口"
        case .currentSpace: return "当前桌面的窗口"
        case .currentApp: return "当前应用的窗口"
        }
    }
}

/// Single modifier used by the switcher hotkeys.
enum SwitcherModifier: String, CaseIterable, Identifiable {
    case command, option, control
    var id: String { rawValue }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        }
    }
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
    var label: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        }
    }
    init(flags: NSEvent.ModifierFlags, default def: SwitcherModifier) {
        if flags.contains(.command) { self = .command }
        else if flags.contains(.option) { self = .option }
        else if flags.contains(.control) { self = .control }
        else { self = def }
    }
}

extension NSEvent.ModifierFlags {
    /// "⌃⌥⇧⌘" in the canonical macOS order.
    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }

    var spelledOut: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃ Control") }
        if contains(.option) { parts.append("⌥ Option") }
        if contains(.shift) { parts.append("⇧ Shift") }
        if contains(.command) { parts.append("⌘ Command") }
        return parts.joined(separator: " + ")
    }
}

// MARK: Legacy (≤ 1.1) profile model, decoded for migration and still written
// so older SwitchMux builds sharing the same synced config keep working.
struct LegacyProfile: Codable {
    var id: UUID
    var name: String
    var mode: String          // "dock" | "switcher" | "custom"
    var sortOrder: Int
    var actions: [AppEntry]
    var characters: String
    var includeFinder: Bool
}
