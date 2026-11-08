import AppKit
import SwiftUI
import ServiceManagement
import Combine

/// Snapshot of every persisted setting (synced as one JSON file via ConfigSync).
///
/// Every field is optional so configs written by any older or newer build
/// decode. When saving, the legacy (≤ 1.1) fields are still filled in so an
/// older SwitchMux on another Mac sharing the iCloud config keeps working.
struct SettingsSnapshot: Codable {
    // Current model
    var apps: [AppEntry]?
    var appWindowSwitcherEnabled: Bool?
    var appWindowSwitcherModifiers: UInt?

    // Shared with older builds
    var enabled: Bool?
    var activateModifiers: UInt?
    var displayDelay: Double?
    var hideAfter: Double?
    var hideOnRepeat: Bool?
    var showOnActiveScreen: Bool?
    var switchByReleasing: Bool?
    var doublePressToggle: Bool?
    var windowSwitcherEnabled: Bool?
    var windowSwitcherModifiers: UInt?
    var windowScope: String?
    var includeMinimizedWindows: Bool?
    var includeHiddenAppWindows: Bool?
    var windowSwitcherScale: Double?
    var barSizeScale: Double?
    var barOpacity: Double?
    var borderWidth: Double?
    var verticalPosition: String?
    var horizontalPosition: String?
    var silentApps: [SilentEntry]?
    var usageCount: Int?
    var usageByDay: [String: Int]?
    var welcomeShown: Bool?
    var showStatusIcon: Bool?
    var autoUpdateCheck: Bool?

    // Legacy only (read for migration, written for backward compatibility)
    var profiles: [LegacyProfile]?
    var activeProfileID: UUID?
    var switcherFilter: [String]?
    var mruBundleIDs: [String]?
}

/// All user-facing settings. Persistence is a single JSON snapshot kept by
/// ConfigSync (iCloud Drive by default, local mirror otherwise), so config
/// survives ad-hoc rebuilds and syncs across machines.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let legacyProfileID = UUID(uuidString: "5D1C0A55-0000-4000-8000-000000000001")!

    private var saveWorkItem: DispatchWorkItem?
    private var applyingExternal = false
    private var observerBag = Set<AnyCancellable>()
    private var needsMigrationSave = false

    // MARK: App Bar
    @Published var apps: [AppEntry]
    @Published var enabled: Bool
    @Published var activateModifiers: NSEvent.ModifierFlags
    /// Delay before the App Bar appears. -1 = never (blind shortcuts only).
    @Published var displayDelay: TimeInterval
    @Published var hideAfter: TimeInterval
    @Published var hideOnRepeat: Bool
    @Published var showOnActiveScreen: Bool
    @Published var switchByReleasing: Bool
    @Published var doublePressToggle: Bool

    // MARK: Window switchers
    @Published var windowSwitcherEnabled: Bool
    @Published var windowSwitcherModifier: SwitcherModifier
    @Published var appWindowSwitcherEnabled: Bool
    @Published var appWindowSwitcherModifier: SwitcherModifier
    @Published var windowScope: WindowScope
    @Published var includeMinimizedWindows: Bool
    @Published var includeHiddenAppWindows: Bool
    @Published var windowSwitcherScale: Double

    // MARK: Appearance
    @Published var barSizeScale: Double
    @Published var barOpacity: Double
    @Published var borderWidth: Double
    @Published var verticalPosition: BarVerticalPosition
    @Published var horizontalPosition: BarHorizontalPosition

    // MARK: Silent / misc
    @Published var silentApps: [SilentEntry]
    /// Switch counts kept in the config by builds up to 1.2.1 (which still
    /// update them). Newer builds count per Mac, see `UsageStore`.
    @Published var usageCount: Int
    @Published var usageByDay: [String: Int]
    @Published var welcomeShown: Bool
    @Published var showStatusIcon: Bool
    @Published var autoUpdateCheck: Bool

    /// Most-recently-activated bundle IDs. In-memory only: it changes on every
    /// app switch and must not churn the synced config file.
    private(set) var mruBundleIDs: [String] = []

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("SwitchMux: failed to toggle launch at login: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: Defaults
    static let defaultBarSizeScale = 1.0
    static let defaultBarOpacity = 0.95
    static let defaultBorderWidth = 3.0

    // MARK: Init
    private init() {
        apps = []
        enabled = true
        activateModifiers = .option
        displayDelay = 0.15
        hideAfter = 0
        hideOnRepeat = true
        showOnActiveScreen = true
        switchByReleasing = true
        doublePressToggle = true
        windowSwitcherEnabled = true
        windowSwitcherModifier = .command
        appWindowSwitcherEnabled = true
        appWindowSwitcherModifier = .option
        windowScope = .allWindows
        includeMinimizedWindows = true
        includeHiddenAppWindows = true
        windowSwitcherScale = 1.0
        barSizeScale = Self.defaultBarSizeScale
        barOpacity = Self.defaultBarOpacity
        borderWidth = Self.defaultBorderWidth
        verticalPosition = .middle
        horizontalPosition = .center
        silentApps = []
        usageCount = 0
        usageByDay = [:]
        welcomeShown = false
        showStatusIcon = true
        autoUpdateCheck = true

        let sync = ConfigSync.shared
        sync.seedNeutralKeys = ["welcomeShown"]
        sync.derivedKeys = ["profiles": "apps", "activeProfileID": "apps",
                            "switcherFilter": "apps", "mruBundleIDs": "apps"]
        if let snap = sync.load(SettingsSnapshot.self) {
            apply(snap)
            saveMigration()
        } else {
            // First run: start from the Dock with Finder first, until iCloud
            // delivers the config of the user's other Macs (if any).
            apps = Self.dockEntries(includeFinder: true)
            sync.seed(snapshot())
        }

        objectWillChange
            .sink { [weak self] in self?.scheduleSave() }
            .store(in: &observerBag)

        sync.onChange = { [weak self] in
            guard let self, let snap = ConfigSync.shared.load(SettingsSnapshot.self) else { return }
            // The objectWillChange sink runs synchronously, so this covers apply().
            self.applyingExternal = true
            self.apply(snap)
            self.applyingExternal = false
            // After the sync that delivered it has finished.
            DispatchQueue.main.async { self.saveMigration() }
        }
        sync.flushPendingEdits = { [weak self] in self?.flushPendingSave() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.flushPendingSave()
            }
        sync.start()
    }

    private func scheduleSave() {
        guard !applyingExternal else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Stores the app list derived from an older build's `profiles`, so every
    /// Mac gets it as `apps`. Not an edit: it keeps the times it came with.
    private func saveMigration() {
        guard needsMigrationSave else { return }
        needsMigrationSave = false
        flushPendingSave()
        ConfigSync.shared.save(snapshot(), edit: false)
    }

    /// Saves an edit still waiting for its debounce right away.
    func flushPendingSave() {
        guard let work = saveWorkItem else { return }
        work.cancel()
        saveWorkItem = nil
        ConfigSync.shared.save(snapshot())
    }

    func snapshot() -> SettingsSnapshot {
        let legacy = LegacyProfile(id: Self.legacyProfileID, name: "自定义配置", mode: "custom",
                                   sortOrder: 0, actions: apps, characters: "1234567890",
                                   includeFinder: false)
        return SettingsSnapshot(
            apps: apps,
            appWindowSwitcherEnabled: appWindowSwitcherEnabled,
            appWindowSwitcherModifiers: appWindowSwitcherModifier.flags.rawValue,
            enabled: enabled,
            activateModifiers: activateModifiers.rawValue,
            displayDelay: displayDelay,
            hideAfter: hideAfter,
            hideOnRepeat: hideOnRepeat,
            showOnActiveScreen: showOnActiveScreen,
            switchByReleasing: switchByReleasing,
            doublePressToggle: doublePressToggle,
            windowSwitcherEnabled: windowSwitcherEnabled,
            windowSwitcherModifiers: windowSwitcherModifier.flags.rawValue,
            windowScope: windowScope.rawValue,
            includeMinimizedWindows: includeMinimizedWindows,
            includeHiddenAppWindows: includeHiddenAppWindows,
            windowSwitcherScale: windowSwitcherScale,
            barSizeScale: barSizeScale,
            barOpacity: barOpacity,
            borderWidth: borderWidth,
            verticalPosition: verticalPosition.rawValue,
            horizontalPosition: horizontalPosition.rawValue,
            silentApps: silentApps,
            usageCount: usageCount,
            usageByDay: usageByDay,
            welcomeShown: welcomeShown,
            showStatusIcon: showStatusIcon,
            autoUpdateCheck: autoUpdateCheck,
            profiles: [legacy],
            activeProfileID: legacy.id,
            switcherFilter: [],
            mruBundleIDs: []
        )
    }

    private func apply(_ s: SettingsSnapshot) {
        if let a = s.apps {
            if let edited = Self.legacyEdit(s, apps: a) {
                apps = Self.sanitized(edited)
                needsMigrationSave = true
            } else {
                apps = Self.sanitized(a)
            }
        } else if let profiles = s.profiles, !profiles.isEmpty {
            apps = Self.sanitized(Self.migrate(profiles: profiles, activeID: s.activeProfileID))
            needsMigrationSave = true
        }
        enabled = s.enabled ?? enabled
        if let m = s.activateModifiers {
            let flags = NSEvent.ModifierFlags(rawValue: m).intersection(KeyChord.relevant)
            activateModifiers = flags.isEmpty ? .option : flags
        }
        displayDelay = s.displayDelay ?? displayDelay
        hideAfter = s.hideAfter ?? hideAfter
        hideOnRepeat = s.hideOnRepeat ?? hideOnRepeat
        showOnActiveScreen = s.showOnActiveScreen ?? showOnActiveScreen
        switchByReleasing = s.switchByReleasing ?? switchByReleasing
        doublePressToggle = s.doublePressToggle ?? doublePressToggle
        windowSwitcherEnabled = s.windowSwitcherEnabled ?? windowSwitcherEnabled
        if let m = s.windowSwitcherModifiers {
            windowSwitcherModifier = SwitcherModifier(flags: NSEvent.ModifierFlags(rawValue: m), default: .command)
        }
        appWindowSwitcherEnabled = s.appWindowSwitcherEnabled ?? appWindowSwitcherEnabled
        if let m = s.appWindowSwitcherModifiers {
            appWindowSwitcherModifier = SwitcherModifier(flags: NSEvent.ModifierFlags(rawValue: m), default: .option)
        }
        windowScope = s.windowScope.flatMap(WindowScope.init(rawValue:)) ?? windowScope
        includeMinimizedWindows = s.includeMinimizedWindows ?? includeMinimizedWindows
        includeHiddenAppWindows = s.includeHiddenAppWindows ?? includeHiddenAppWindows
        windowSwitcherScale = s.windowSwitcherScale ?? windowSwitcherScale
        barSizeScale = s.barSizeScale ?? barSizeScale
        barOpacity = s.barOpacity ?? barOpacity
        borderWidth = s.borderWidth ?? borderWidth
        verticalPosition = s.verticalPosition.flatMap(BarVerticalPosition.init(rawValue:)) ?? verticalPosition
        horizontalPosition = s.horizontalPosition.flatMap(BarHorizontalPosition.init(rawValue:)) ?? horizontalPosition
        silentApps = s.silentApps ?? silentApps
        usageCount = s.usageCount ?? usageCount
        usageByDay = s.usageByDay ?? usageByDay
        welcomeShown = s.welcomeShown ?? welcomeShown
        showStatusIcon = s.showStatusIcon ?? showStatusIcon
        autoUpdateCheck = s.autoUpdateCheck ?? autoUpdateCheck
    }

    /// Drops bindings that can't be typed (older builds recorded Esc / Tab as
    /// a "character") and duplicate keys (first one wins). A character that
    /// can't be mapped to a key on this layout is kept as-is (the shared config
    /// may come from a Mac with another layout); the UI flags it.
    static func sanitized(_ list: [AppEntry]) -> [AppEntry] {
        var used = Set<UInt16>()
        return list.map { entry in
            var e = entry
            guard let ch = e.character else { e.keyCode = nil; return e }
            let printable = !ch.isEmpty && ch.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
            }
            guard printable else { e.character = nil; e.keyCode = nil; return e }
            guard let code = e.triggerKeyCode else { return e }
            if used.contains(code) {
                e.character = nil
                e.keyCode = nil
            } else {
                used.insert(code)
                e.keyCode = code
            }
            return e
        }
    }

    // MARK: Migration from ≤ 1.1 profiles
    /// Dock / Switcher / multiple custom profiles collapse into one app list:
    /// the active custom profile wins; a Dock profile becomes its Dock apps.
    static func migrate(profiles: [LegacyProfile], activeID: UUID?) -> [AppEntry] {
        let sorted = profiles.sorted { $0.sortOrder < $1.sortOrder }
        let active = sorted.first { $0.id == activeID } ?? sorted.first
        if let active, active.mode == "custom", !active.actions.isEmpty {
            return active.actions
        }
        if let active, active.mode == "dock" {
            return dockEntries(includeFinder: active.includeFinder, characters: active.characters)
        }
        if let custom = sorted.first(where: { $0.mode == "custom" && !$0.actions.isEmpty }) {
            return custom.actions
        }
        return dockEntries(includeFinder: true, characters: active?.characters ?? "1234567890")
    }

    /// Builds ≤ 1.1 only edit `profiles` and drop `apps`, which the merge then
    /// keeps from before. If the profile no longer lists the same apps and keys
    /// as `apps`, the list was edited there: returns that list.
    static func legacyEdit(_ s: SettingsSnapshot, apps: [AppEntry]) -> [AppEntry]? {
        let sorted = (s.profiles ?? []).sorted { $0.sortOrder < $1.sortOrder }
        guard let active = sorted.first(where: { $0.id == s.activeProfileID }) ?? sorted.first else { return nil }
        // An emptied list is kept, not replaced by the Dock as in `migrate`.
        let edited = active.mode == "custom" ? active.actions
            : migrate(profiles: sorted, activeID: active.id)
        func bindings(_ list: [AppEntry]) -> [[String?]] { list.map { [$0.path, $0.character] } }
        guard bindings(edited) != bindings(apps) else { return nil }
        // Those builds drop `keyCode`: keep it where the binding is unchanged
        // (it can come from a Mac with another keyboard layout).
        return edited.map { entry in
            var e = entry
            if let same = apps.first(where: { $0.path == e.path && $0.character == e.character }) {
                e.keyCode = same.keyCode
            }
            return e
        }
    }

    static func dockEntries(includeFinder: Bool, characters: String = "1234567890") -> [AppEntry] {
        var urls: [URL] = []
        if includeFinder { urls.append(DockReader.finderURL) }
        urls.append(contentsOf: DockReader.apps().map(\.url).filter { $0.path != DockReader.finderURL.path })
        let chars = Array(characters.lowercased()).map(String.init)
        return urls.enumerated().map { i, url in
            AppEntry.make(url: url, character: i < chars.count ? chars[i] : nil)
        }
    }

    // MARK: App list mutations
    func containsApp(path: String) -> Bool {
        apps.contains { $0.path == path }
    }

    /// Appends apps that aren't in the list yet, each with the next free key.
    func addApps(_ urls: [URL]) {
        var list = apps
        for url in urls where url.pathExtension == "app" && !list.contains(where: { $0.path == url.path }) {
            list.append(AppEntry.make(url: url, character: Self.nextFreeCharacter(in: list)))
        }
        apps = list
    }

    static func nextFreeCharacter(in list: [AppEntry]) -> String? {
        let used = Set(list.compactMap(\.triggerKeyCode))
        return KeyCodes.assignmentOrder.first { ch in
            guard let code = KeyCodes.code(for: ch) else { return false }
            return !used.contains(code)
        }
    }

    /// Re-assign 1…0, Q…P… from top to bottom.
    func reassignKeys() {
        var list = apps
        for i in list.indices {
            let ch = i < KeyCodes.assignmentOrder.count ? KeyCodes.assignmentOrder[i] : nil
            list[i].character = ch
            list[i].keyCode = ch.flatMap { KeyCodes.code(for: $0) }
        }
        apps = list
    }

    func clearKeys() {
        var list = apps
        for i in list.indices { list[i].character = nil; list[i].keyCode = nil }
        apps = list
    }

    /// Binds a key to an app. If another app had it, that app loses it and its
    /// name is returned so the UI can say so.
    @discardableResult
    func bind(appID: UUID, keyCode: UInt16?, character: String?) -> String? {
        var list = apps
        guard let target = list.firstIndex(where: { $0.id == appID }) else { return nil }
        var displaced: String?
        if let keyCode {
            for i in list.indices where list[i].id != appID && list[i].triggerKeyCode == keyCode {
                displaced = list[i].name
                list[i].character = nil
                list[i].keyCode = nil
            }
        }
        list[target].character = character
        list[target].keyCode = keyCode
        apps = list
        return displaced
    }

    // MARK: Misc
    func silentEntry(for bundleID: String) -> SilentEntry? {
        silentApps.first { $0.bundleID == bundleID }
    }

    /// App activation (any source): feeds the MRU order only.
    func noteActivated(_ bundleID: String) {
        mruBundleIDs.removeAll { $0 == bundleID }
        mruBundleIDs.insert(bundleID, at: 0)
        if mruBundleIDs.count > 64 { mruBundleIDs.removeLast(mruBundleIDs.count - 64) }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
