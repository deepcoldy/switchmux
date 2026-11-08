import AppKit

// Lightweight test runner (no XCTest with Command Line Tools). Run: Tests/run.sh

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg) (line \(line))") }
}
func done() -> Never {
    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// Tests/run.sh runs this once per scenario, each with fresh folders (the
// stores are singletons that load once per process).
let environment = ProcessInfo.processInfo.environment
let scenario = environment["SWITCHMUX_TEST_SCENARIO"] ?? "main"
let configDir = URL(fileURLWithPath: environment["SWITCHMUX_CONFIG_DIR"] ?? NSTemporaryDirectory())
let cloudDir = environment["SWITCHMUX_CLOUD_DIR"].map { URL(fileURLWithPath: $0) }

func spin(timeout: TimeInterval = 10, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return done()
}
func refresh() -> ConfigSync.Outcome? {
    var outcome: ConfigSync.Outcome?
    ConfigSync.shared.refreshFromCloud { outcome = $0 }
    _ = spin { outcome != nil }
    return outcome
}
func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
func cloudJSON() -> [String: Any]? { cloudDir.flatMap { readJSON($0.appendingPathComponent("config.json")) } }
func writeCloud(_ json: [String: Any], modified: Date? = nil) {
    guard let cloudDir else { return }
    let url = cloudDir.appendingPathComponent("config.json")
    try! FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
    if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}
func appNames(_ json: [String: Any]?) -> [String] {
    (json?["apps"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
}
func stamped(_ json: ConfigMerge.JSON, times: [String: Double] = [:], baseline: Double = 0,
             seeded: Bool = false) -> ConfigMerge.JSON {
    var stamp = ConfigMerge.Stamp(baseline: baseline, seeded: seeded)
    stamp.times = times
    return ConfigMerge.stamped(json, stamp)
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
let legacyAppNames = ["Ghostty", "Chrome", "Dup", "Code"]

if scenario == "upgrade" {
    print("Upgrading a Mac whose last build was ≤ 1.1")
    // Its local copy was rewritten recently; iCloud has an app list a current
    // build edited earlier.
    try! FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try! Data(legacyJSON.utf8).write(to: configDir.appendingPathComponent("config.json"))
    let edited = Date().timeIntervalSince1970 - 1000
    writeCloud(stamped([
        "apps": [["id": UUID().uuidString, "name": "X", "path": "/Applications/X.app", "character": "x"],
                 ["id": UUID().uuidString, "name": "Y", "path": "/Applications/Y.app", "character": "y"]],
        "barOpacity": 0.5,
    ], times: ["apps": edited], baseline: edited - 1000))
    let upgraded = SettingsStore.shared
    check(spin { ConfigSync.shared.lastSynced != nil }, "the first sync completes")
    check(upgraded.apps.map(\.name) == ["X", "Y"], "iCloud's app list wins over the one migrated from the old local copy")
    check(upgraded.barOpacity == 0.5, "…as do its other settings")
    check(appNames(cloudJSON()) == ["X", "Y"], "…and iCloud keeps them")
    done()
}

if scenario == "seed" {
    print("First run on a new Mac")
    let fresh = SettingsStore.shared
    if case .unavailable? = refresh() { check(true, "a manual refresh with nothing in iCloud says so") }
    else { check(false, "a manual refresh with nothing in iCloud says so") }
    // This Mac's seed reached iCloud (after the grace period), then the user
    // finishes the welcome window.
    check(!fresh.welcomeShown, "the welcome window is pending on a new Mac")
    try! FileManager.default.createDirectory(at: cloudDir!, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: configDir.appendingPathComponent("config.json"),
                                      to: cloudDir!.appendingPathComponent("config.json"))
    fresh.welcomeShown = true
    _ = refresh()
    check(fresh.welcomeShown && cloudJSON()?["welcomeShown"] as? Bool == true,
          "finishing it sticks after this Mac's seed is in iCloud")
    // Another new Mac uploaded its first-run seed meanwhile.
    writeCloud(stamped(["apps": [["id": UUID().uuidString, "name": "S", "path": "/Applications/S.app"]],
                        "barOpacity": 0.3], seeded: true))
    _ = refresh()
    check(!FileManager.default.fileExists(atPath: configDir.appendingPathComponent("config.base.json").path),
          "another Mac's first-run seed never becomes the merge base")
    // Then a ≤ 1.1 build saves its app list (it knows only `profiles`).
    writeCloud(try! JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as! [String: Any])
    _ = refresh()
    check(fresh.apps.map(\.name) == legacyAppNames, "the older build's app list replaces the seeds")
    check(spin { appNames(cloudJSON()) == legacyAppNames }, "…and is stored as `apps` for every Mac")
    done()
}

if scenario == "usage" {
    print("Usage counts restored from an older backup")
    let legacyUsage = SettingsStore.shared.usageCount
    let id = UsageStore.hardwareID() ?? "restored-mac"
    // The local file is older than this Mac's iCloud file on Nov 5, newer on Nov 9.
    try! JSONSerialization.data(withJSONObject: ["deviceID": id, "count": 15,
                                                 "byDay": ["2026-11-01": 10, "2026-11-09": 5]])
        .write(to: configDir.appendingPathComponent("usage.json"))
    let usageDir = cloudDir!.appendingPathComponent("usage")
    let ownFile = usageDir.appendingPathComponent("\(id).json")
    try! FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["deviceID": id, "count": 500,
                                                 "byDay": ["2026-11-01": 10, "2026-11-05": 490]])
        .write(to: ownFile)
    let usage = UsageStore.shared
    check(spin(timeout: 5) { usage.total == legacyUsage + 505 },
          "counts only this Mac's iCloud file has are kept, without counting a day twice")
    for _ in 0..<3 { usage.record() }
    usage.flush()
    check(spin(timeout: 5) {
        let json = readJSON(ownFile)
        return json?["count"] as? Int == 508 && (json?["byDay"] as? [String: Int])?["2026-11-05"] == 490
    }, "…and this Mac's iCloud file keeps them")
    check(readJSON(configDir.appendingPathComponent("usage.json"))?["count"] as? Int == 508, "…as does the local file")
    done()
}

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

print("ConfigMerge")
func int(_ json: ConfigMerge.JSON?, _ key: String) -> Int? { (json?[key] as? NSNumber)?.intValue }

do {
    let base: ConfigMerge.JSON = ["a": 1, "b": 1]
    let merged = ConfigMerge.merge(base: base,
                                   local: stamped(["a": 2, "b": 1], times: ["a": 200]),
                                   remote: stamped(["a": 1, "b": 2], times: ["b": 100]))
    check(int(merged, "a") == 2 && int(merged, "b") == 2, "edits of different keys on two Macs both survive")
    check(ConfigMerge.Stamp(merged)?.times == ["a": 200, "b": 100], "…keeping each key's edit time")

    let newerRemote = ConfigMerge.merge(base: ["a": 1], local: stamped(["a": 2], times: ["a": 100]),
                                        remote: stamped(["a": 3], times: ["a": 200]))
    let newerLocal = ConfigMerge.merge(base: ["a": 1], local: stamped(["a": 2], times: ["a": 300]),
                                       remote: stamped(["a": 3], times: ["a": 200]))
    check(int(newerRemote, "a") == 3 && int(newerLocal, "a") == 2, "same key edited on both: newer edit wins")

    let oldBuild = ConfigMerge.merge(base: ["a": 1, "apps": 1],
                                     local: stamped(["a": 1, "apps": 2], times: ["apps": 100]),
                                     remote: ["a": 5], remoteFileTime: 50)
    check(int(oldBuild, "a") == 5, "older build's change is applied")
    check(int(oldBuild, "apps") == 2, "…but a key it dropped counts as unchanged, not deleted")
    let untouched = ConfigMerge.merge(base: ["apps": 1], local: stamped(["apps": 1], baseline: 10),
                                      remote: ["a": 5], remoteFileTime: 50)
    check(int(untouched, "apps") == 1, "…also when neither side changed it")

    let seed = stamped(["apps": 9, "a": 0, "welcomeShown": true], seeded: true)
    let real = stamped(["a": 7, "profiles": 3], baseline: 50)
    let joined = ConfigMerge.merge(base: nil, local: seed, remote: real)
    check(int(joined, "a") == 7 && int(joined, "profiles") == 3, "first-run seed takes the iCloud config")
    check(joined?["apps"] == nil, "…without keeping Dock apps the iCloud file lacks")
    check(ConfigMerge.Stamp(joined)?.seeded == false, "…and is no longer a seed")

    let edited = ConfigMerge.merge(base: nil, local: stamped(["apps": 9, "a": 9], times: ["a": 100]),
                                   remote: ["a": 7, "b": 3], remoteFileTime: 50)
    check(int(edited, "a") == 9 && int(edited, "b") == 3 && edited?["apps"] == nil,
          "edits made before the first sync win, untouched seed keys don't")
    let welcomed = ConfigMerge.merge(base: nil,
                                     local: stamped(["apps": 9, "welcomeShown": true], times: ["welcomeShown": 100], seeded: true),
                                     remote: stamped(["apps": 8, "welcomeShown": false], seeded: true))
    check(welcomed?["welcomeShown"] as? Bool == true && int(welcomed, "apps") == 8,
          "between two seeds, keys changed since seeding win, untouched ones don't")
    check(int(ConfigMerge.merge(base: nil, local: stamped(["a": 1], baseline: 5),
                                remote: stamped(["a": 2], seeded: true)), "a") == 1,
          "a seed in iCloud never overrides a real config")

    check(ConfigMerge.changedKeys(from: stamped(["a": 1, "b": [1, 2]]), to: ["a": 1, "b": [1, 3]]) == ["b"],
          "changedKeys compares values and ignores metadata")

    let rewritten = ConfigMerge.merge(base: ["a": 1, "b": 1],
                                      local: stamped(["a": 1, "b": 1], times: ["a": 10, "b": 10]),
                                      remote: ["a": 1, "b": 2], remoteFileTime: 500)
    check(int(rewritten, "b") == 2 && ConfigMerge.Stamp(rewritten)?.times == ["a": 10, "b": 500],
          "an older build's file date only dates the keys it changed")
}

do {
    let legacy: [(json: ConfigMerge.JSON, fileTime: Double)] = [(["a": 1], 10), (["a": 3], 30), (["a": 2], 20)]
    check(int(ConfigMerge.resolve(legacy), "a") == 3, "resolve: newest file wins among older-build versions")
    let mixed: [(json: ConfigMerge.JSON, fileTime: Double)] = [
        (["a": 1, "b": 1], 100),
        (stamped(["a": 2, "b": 2], times: ["a": 50]), 40),
        (stamped(["a": 4, "b": 4], seeded: true), 200),
    ]
    let resolved = ConfigMerge.resolve(mixed)
    check(int(resolved, "a") == 2, "resolve: a real edit beats versions rewritten by older builds")
    check(int(resolved, "b") == 1, "resolve: otherwise the newest real version, never the seed")
    let shuffled = ConfigMerge.resolve([mixed[2], mixed[0], mixed[1]])
    check(ConfigMerge.sameContent(resolved, shuffled), "resolve is independent of version order")
    let withSeed = ConfigMerge.resolve([(["a": 1], 10), (stamped(["a": 2, "apps": 9], seeded: true), 20)])
    check(withSeed?["apps"] == nil, "resolve: a seed doesn't add keys the real versions lack")
}

print("App list edits made by builds up to 1.1")
do {
    let a = AppEntry(name: "A", path: "/Applications/A.app", character: "1", keyCode: 99)
    let b = AppEntry(name: "B", path: "/Applications/B.app", character: "2")
    func profile(_ actions: [AppEntry]) -> LegacyProfile {
        LegacyProfile(id: UUID(), name: "p", mode: "custom", sortOrder: 0, actions: actions,
                      characters: "1234567890", includeFinder: false)
    }
    // Those builds drop `keyCode` when they save.
    let saved = [a, b].map { entry -> AppEntry in var e = entry; e.keyCode = nil; return e }
    var snap = SettingsSnapshot()
    snap.profiles = [profile(saved)]
    check(SettingsStore.legacyEdit(snap, apps: [a, b]) == nil, "a rewrite without changes is no edit")
    snap.profiles = [profile([saved[1], saved[0]])]
    let reordered = SettingsStore.legacyEdit(snap, apps: [a, b])
    check(reordered?.map(\.name) == ["B", "A"] && reordered?[1].keyCode == 99,
          "a reordered list is taken, keeping recorded key codes")
    snap.profiles = [profile([])]
    check(SettingsStore.legacyEdit(snap, apps: [a, b])?.isEmpty == true, "an emptied list is taken")
    check(SettingsStore.legacyEdit(snap, apps: []) == nil, "…and not refilled from the Dock afterwards")
}

do {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot())) as! ConfigMerge.JSON
    var stamp = ConfigMerge.Stamp(baseline: 1, editedBy: "Mac")
    stamp.times = ["apps": 2]
    let data = try JSONSerialization.data(withJSONObject: ConfigMerge.stamped(json, stamp))
    _ = try JSONDecoder().decode(OldSnapshot.self, from: data)
    check(true, "stamped config still decodes in older builds")
} catch {
    check(false, "older builds cannot decode stamped config: \(error)")
}

if let cloudDir {
    print("ConfigSync with a stand-in iCloud folder")
    let sync = ConfigSync.shared
    let cloudFile = cloudDir.appendingPathComponent("config.json")

    // This Mac edited its app list (first run, not synced yet); meanwhile another
    // Mac changed the bar opacity, and has an older app list.
    store.flushPendingSave()
    let now = Date().timeIntervalSince1970
    var other = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot())) as! ConfigMerge.JSON
    other["barOpacity"] = 0.42
    other["apps"] = [["id": UUID().uuidString, "name": "Z", "path": "/Applications/Z.app"]]
    var otherStamp = ConfigMerge.Stamp(baseline: now - 1000, editedBy: "Other Mac")
    otherStamp.times = ["barOpacity": now - 10]
    writeCloud(ConfigMerge.stamped(other, otherStamp))

    let first = refresh()
    if case .updated? = first { check(true, "manual refresh reports new settings") }
    else { check(false, "manual refresh reports new settings (got \(first?.message ?? "timeout"))") }
    check(store.barOpacity == 0.42, "the other Mac's change is applied")
    check(store.apps.map(\.name) == ["A", "B"], "…and this Mac's newer app list is kept")
    let pushed = cloudJSON()
    check((pushed?["barOpacity"] as? NSNumber)?.doubleValue == 0.42 && appNames(pushed) == ["A", "B"],
          "the merged config is written to iCloud")
    check(ConfigMerge.Stamp(pushed)?.savedBy != nil, "…stamped with the writing Mac")
    if let data = try? Data(contentsOf: cloudFile) {
        check((try? JSONDecoder().decode(OldSnapshot.self, from: data)) != nil, "…readable by older builds")
    }

    store.hideAfter = 2.75
    check(spin { (cloudJSON()?["hideAfter"] as? NSNumber)?.doubleValue == 2.75 },
          "a local edit reaches iCloud on its own")

    // A ≤ 1.1 build rewrote the file: no `_sync`, no `apps`.
    var legacy = cloudJSON() ?? [:]
    legacy[ConfigMerge.metaKey] = nil
    legacy["apps"] = nil
    legacy["displayDelay"] = 0.77
    writeCloud(legacy)
    _ = refresh()
    check(store.displayDelay == 0.77, "older build's edit is applied")
    check(store.apps.map(\.name) == ["A", "B"], "…without losing the app list it doesn't know")
    check(sync.olderBuildWriter != nil, "…and the older writer is reported")

    if case .upToDate? = refresh() { check(true, "refreshing again finds nothing new") }
    else { check(false, "refreshing again finds nothing new") }

    // A ≤ 1.1 build edits the app list: it rewrites `profiles` only.
    var edit = cloudJSON() ?? [:]
    edit[ConfigMerge.metaKey] = nil
    edit["apps"] = nil
    if var profiles = edit["profiles"] as? [[String: Any]], var actions = profiles.first?["actions"] as? [[String: Any]] {
        for i in actions.indices { actions[i]["keyCode"] = nil }
        actions[1]["character"] = "3"
        actions.append(["id": UUID().uuidString, "name": "C", "path": "/Applications/C.app", "character": "4"])
        profiles[0]["actions"] = actions
        edit["profiles"] = profiles
    }
    writeCloud(edit)
    _ = refresh()
    check(store.apps.map(\.name) == ["A", "B", "C"] && store.apps[1].character == "3",
          "an app list edited by an older build is applied")
    check(spin { appNames(cloudJSON()) == ["A", "B", "C"] }, "…and stored as `apps` for every Mac")
    check(spin { sync.olderBuildWriter == nil }, "the older-build warning clears once a current build wrote iCloud")
    // What an older build left behind, unchanged since, is no news.
    var leftover = cloudJSON() ?? [:]
    leftover[ConfigMerge.metaKey] = nil
    writeCloud(leftover)
    _ = refresh()
    check(sync.olderBuildWriter == nil, "…and stays clear while no older build changes the file")

    // An older build rewrites the file as it always does (`profiles` without
    // `keyCode`, its own MRU list), later edits the app list, and before that
    // edit arrives, this Mac changes an unrelated setting.
    func olderBuildCopy(_ edit: (inout [[String: Any]]) -> Void = { _ in }) -> [String: Any] {
        var json = cloudJSON() ?? [:]
        json[ConfigMerge.metaKey] = nil
        json["apps"] = nil
        json["mruBundleIDs"] = ["com.apple.finder"]
        if var profiles = json["profiles"] as? [[String: Any]], var actions = profiles.first?["actions"] as? [[String: Any]] {
            for i in actions.indices { actions[i]["keyCode"] = nil }
            edit(&actions)
            profiles[0]["actions"] = actions
            json["profiles"] = profiles
        }
        return json
    }
    writeCloud(olderBuildCopy(), modified: Date().addingTimeInterval(-60))
    _ = refresh()
    writeCloud(olderBuildCopy { $0.append(["id": UUID().uuidString, "name": "D", "path": "/Applications/D.app", "character": "5"]) },
               modified: Date().addingTimeInterval(-20))
    store.barOpacity = 0.6
    _ = refresh()
    check(store.apps.map(\.name) == ["A", "B", "C", "D"] && store.barOpacity == 0.6,
          "an older build's app list edit survives an unrelated edit made here meanwhile")
    check(spin { appNames(cloudJSON()) == ["A", "B", "C", "D"] && (cloudJSON()?["barOpacity"] as? NSNumber)?.doubleValue == 0.6 },
          "…and both reach iCloud")

    let configBefore = try? Data(contentsOf: cloudFile)
    let usageDir = cloudDir.appendingPathComponent("usage")
    let legacyUsage = store.usageCount
    var earlier = 0
    if let id = UsageStore.hardwareID() {
        // Counts this Mac uploaded before its local usage file was lost.
        earlier = 500
        try! FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["deviceID": id, "count": earlier, "byDay": ["2026-01-01": earlier]])
            .write(to: usageDir.appendingPathComponent("\(id).json"))
    }
    let usage = UsageStore.shared
    check(spin(timeout: 5) { usage.total == legacyUsage + earlier }, "this Mac's earlier counts are taken over from iCloud")
    for _ in 0..<100 { usage.record() }
    usage.flush()
    let ownFile = usageDir.appendingPathComponent("\(UsageStore.hardwareID() ?? "-").json")
    check(spin(timeout: 5) { (readJSON(ownFile)?["count"] as? Int) == earlier + 100 },
          "switch counts go to this Mac's own usage file, on top of the earlier ones")
    _ = spin(timeout: 1.5) { false }
    check((try? Data(contentsOf: cloudFile)) == configBefore, "…and never rewrite the shared config")
    check(usage.total == legacyUsage + earlier + 100, "usage total counts the switches")
}

done()
