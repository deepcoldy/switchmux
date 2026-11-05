import AppKit

// Lightweight test runner (no XCTest with Command Line Tools). Run: Tests/run.sh

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg) (line \(line))") }
}

/// Exact shape of the ≤ 1.1 snapshot (all non-optional fields are required
/// there). A new config must still decode with it, or an older SwitchMux on
/// another Mac sharing the iCloud file would reset everything to defaults.
struct OldSnapshot: Decodable {
    struct OldAction: Decodable { var id: UUID; var name: String; var path: String; var bundleID: String?; var character: String? }
    struct OldProfile: Decodable {
        var id: UUID; var name: String; var mode: String; var sortOrder: Int
        var actions: [OldAction]; var characters: String; var includeFinder: Bool
    }
    var profiles: [OldProfile]
    var activeProfileID: UUID?
    var enabled: Bool
    var activateModifiers: UInt
    var displayDelay: Double
    var hideAfter: Double
    var hideOnRepeat: Bool
    var showOnActiveScreen: Bool
    var switchByReleasing: Bool
    var doublePressToggle: Bool
    var switcherFilter: [String]
    var windowSwitcherEnabled: Bool
    var windowSwitcherModifiers: UInt
    var windowScope: String
    var includeMinimizedWindows: Bool
    var includeHiddenAppWindows: Bool
    var windowSwitcherScale: Double
    var barSizeScale: Double
    var barOpacity: Double
    var borderWidth: Double
    var verticalPosition: String
    var horizontalPosition: String
    var silentApps: [SilentEntry]
    var mruBundleIDs: [String]
    var usageCount: Int
    var usageByDay: [String: Int]
    var welcomeShown: Bool
    var showStatusIcon: Bool
    var autoUpdateCheck: Bool?
}

let legacyJSON = """
{"profiles":[
  {"id":"11111111-1111-1111-1111-111111111111","name":"Dock","mode":"dock","sortOrder":0,"actions":[],"characters":"1234567890","includeFinder":false},
  {"id":"22222222-2222-2222-2222-222222222222","name":"自定义配置 1","mode":"custom","sortOrder":2,"characters":"1234567890","includeFinder":false,
   "actions":[
     {"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Ghostty","path":"/Applications/Ghostty.app","bundleID":"com.mitchellh.ghostty","character":"a"},
     {"id":"AAAAAAAA-0000-0000-0000-000000000002","name":"Chrome","path":"/Applications/Google Chrome.app","bundleID":"com.google.Chrome","character":"\\u001b"},
     {"id":"AAAAAAAA-0000-0000-0000-000000000003","name":"Dup","path":"/Applications/Dup.app","character":"a"},
     {"id":"AAAAAAAA-0000-0000-0000-000000000004","name":"Code","path":"/Applications/Code.app","character":"2"}
   ]}],
 "activeProfileID":"22222222-2222-2222-2222-222222222222",
 "enabled":true,"activateModifiers":524288,"displayDelay":-1,"hideAfter":0,"hideOnRepeat":true,
 "showOnActiveScreen":true,"switchByReleasing":true,"doublePressToggle":false,"switcherFilter":[],
 "windowSwitcherEnabled":true,"windowSwitcherModifiers":1048576,"windowScope":"allWindows",
 "includeMinimizedWindows":true,"includeHiddenAppWindows":true,"windowSwitcherScale":1,"barSizeScale":1,
 "barOpacity":0.95,"borderWidth":3,"verticalPosition":"middle","horizontalPosition":"center","silentApps":[],
 "mruBundleIDs":["com.apple.finder"],"usageCount":10,"usageByDay":{"2026-11-01":10},"welcomeShown":true,"showStatusIcon":true}
"""

print("Legacy config decoding + migration")
do {
    let snap = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(legacyJSON.utf8))
    check(snap.apps == nil, "legacy file has no `apps`")
    check(snap.profiles?.count == 1 + 1, "profiles decoded")
    let migrated = SettingsStore.sanitized(SettingsStore.migrate(profiles: snap.profiles!, activeID: snap.activeProfileID))
    check(migrated.map(\.name) == ["Ghostty", "Chrome", "Dup", "Code"], "active custom profile becomes the app list")
    check(migrated[0].character == "a" && migrated[0].keyCode == 0, "valid key kept and key code filled")
    check(migrated[1].character == nil && migrated[1].keyCode == nil, "Esc recorded as a character is dropped")
    check(migrated[2].character == nil, "duplicate key dropped (first one wins)")
    check(migrated[3].triggerKeyCode == 19, "digit 2 maps to key code 19")
} catch {
    check(false, "decode legacy: \(error)")
}

print("KeyChord")
check(KeyChord(48, [.command, .capsLock, .numericPad]) == KeyChord(48, .command), "caps lock / keypad flags ignored")
check(KeyChord(48, [.command, .shift]) != KeyChord(48, .command), "shift distinguishes chords")

print("KeyCodes")
check(KeyCodes.code(for: "Q") == 12, "upper-case lookup")
check(KeyCodes.character(for: 50) == "`", "grave reverse lookup")

print("SettingsStore (isolated config dir)")
let store = SettingsStore.shared
store.apps = [
    AppEntry(name: "A", path: "/Applications/A.app", character: "1"),
    AppEntry(name: "B", path: "/Applications/B.app", character: "2"),
]
let displaced = store.bind(appID: store.apps[1].id, keyCode: 18, character: "1")
check(displaced == "A", "binding a used key reports the previous owner")
check(store.apps[0].triggerKeyCode == nil && store.apps[1].triggerKeyCode == 18, "key moved to the new app")
check(SettingsStore.nextFreeCharacter(in: store.apps) == "2", "next free key skips used ones")
store.reassignKeys()
check(store.apps.map { $0.character ?? "-" } == ["1", "2"], "reassign follows list order")

print("Backward compatibility of written config")
do {
    let data = try JSONEncoder().encode(store.snapshot())
    let old = try JSONDecoder().decode(OldSnapshot.self, from: data)
    check(old.profiles.count == 1 && old.profiles[0].mode == "custom", "older builds see one custom profile")
    check(old.profiles[0].actions.map(\.name) == ["A", "B"], "…containing the same apps")
    check(old.activeProfileID == old.profiles[0].id, "…and it is active")
    let roundTrip = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
    check(roundTrip.apps?.count == 2, "new builds read `apps` back")
} catch {
    check(false, "old build cannot decode new config: \(error)")
}

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) FAILED")
exit(failures == 0 ? 0 : 1)
