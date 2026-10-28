import AppKit
import SwiftUI
import ServiceManagement
import Combine

/// Snapshot of every persisted setting (synced as one JSON file via ConfigSync).
struct SettingsSnapshot: Codable {
    var profiles: [Profile]
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
    // Optional so adding it does not break decoding of older synced configs.
    var autoUpdateCheck: Bool?
}

/// All user-facing settings. Persistence is a single JSON snapshot kept by
/// ConfigSync (iCloud Drive by default, local mirror otherwise), so config
/// survives ad-hoc rebuilds and syncs across machines.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private var saveWorkItem: DispatchWorkItem?
    private var applyingExternal = false

    // MARK: Profiles
    @Published var profiles: [Profile]
    @Published var activeProfileID: UUID?

    var activeProfile: Profile {
        get {
            if let id = activeProfileID, let p = profiles.first(where: { $0.id == id }) { return p }
            return profiles.sorted { $0.sortOrder < $1.sortOrder }.first ?? profiles[0]
        }
        set {
            if let idx = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[idx] = newValue
            }
            activeProfileID = newValue.id
        }
    }

    func profile(_ id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    func update(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
    }

    // MARK: Behavior
    @Published var enabled: Bool
    @Published var activateModifiers: NSEvent.ModifierFlags
    /// Delay before the App Bar appears. -1 = never (blind shortcuts only).
    @Published var displayDelay: TimeInterval
    @Published var hideAfter: TimeInterval
    @Published var hideOnRepeat: Bool
    @Published var showOnActiveScreen: Bool
    @Published var switchByReleasing: Bool
    @Published var doublePressToggle: Bool
    @Published var switcherFilter: [String]

    // MARK: Window switcher
    @Published var windowSwitcherEnabled: Bool
    @Published var windowSwitcherModifiers: NSEvent.ModifierFlags
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
    @Published var mruBundleIDs: [String]
    @Published var usageCount: Int
    @Published var usageByDay: [String: Int]
    @Published var welcomeShown: Bool
    @Published var showStatusIcon: Bool
    @Published var autoUpdateCheck: Bool

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

    // MARK: Init
    private init() {
        // 1. Built-in defaults (also the migration source shape).
        let defaultsProfiles = [
            Profile(name: "Dock", mode: .dock, sortOrder: 0, characters: "1234567890"),
            Profile(name: "Switcher", mode: .switcher, sortOrder: 1, characters: "1234567890"),
            Profile(name: "自定义配置 1", mode: .custom, sortOrder: 2, characters: "1234567890"),
        ]
        profiles = defaultsProfiles
        activeProfileID = defaultsProfiles.first?.id
        enabled = true
        activateModifiers = .option
        displayDelay = 0.15
        hideAfter = 0
        hideOnRepeat = true
        showOnActiveScreen = true
        switchByReleasing = true
        doublePressToggle = true
        switcherFilter = []
        windowSwitcherEnabled = true
        windowSwitcherModifiers = .command
        windowScope = .allWindows
        includeMinimizedWindows = true
        includeHiddenAppWindows = true
        windowSwitcherScale = 1.0
        barSizeScale = 1.0
        barOpacity = 0.95
        borderWidth = 3
        verticalPosition = .middle
        horizontalPosition = .center
        silentApps = []
        mruBundleIDs = []
        usageCount = 0
        usageByDay = [:]
        welcomeShown = false
        showStatusIcon = true
        autoUpdateCheck = true

        // JSON snapshot (iCloud Drive / Application Support) wins if present.
        if let snap = ConfigSync.shared.load(SettingsSnapshot.self) {
            apply(snap)
        } else {
            scheduleSave()
        }

        // Debounced whole-snapshot persistence.
        objectWillChange
            .sink { [weak self] in self?.scheduleSave() }
            .store(in: &observerBag)

        // Live reload when the file changes (another Mac / another process).
        ConfigSync.shared.onChange = { [weak self] in
            guard let self,
                  let snap = ConfigSync.shared.load(SettingsSnapshot.self) else { return }
            self.applyingExternal = true
            self.apply(snap)
            DispatchQueue.main.async { self.applyingExternal = false }
        }
        ConfigSync.shared.watch()
    }

    private var observerBag = Set<AnyCancellable>()

    private func scheduleSave() {
        guard !applyingExternal else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            ConfigSync.shared.save(self.snapshot())
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            profiles: profiles,
            activeProfileID: activeProfileID,
            enabled: enabled,
            activateModifiers: activateModifiers.rawValue,
            displayDelay: displayDelay,
            hideAfter: hideAfter,
            hideOnRepeat: hideOnRepeat,
            showOnActiveScreen: showOnActiveScreen,
            switchByReleasing: switchByReleasing,
            doublePressToggle: doublePressToggle,
            switcherFilter: switcherFilter,
            windowSwitcherEnabled: windowSwitcherEnabled,
            windowSwitcherModifiers: windowSwitcherModifiers.rawValue,
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
            mruBundleIDs: mruBundleIDs,
            usageCount: usageCount,
            usageByDay: usageByDay,
            welcomeShown: welcomeShown,
            showStatusIcon: showStatusIcon,
            autoUpdateCheck: autoUpdateCheck
        )
    }

    private func apply(_ s: SettingsSnapshot) {
        guard !s.profiles.isEmpty else { return }
        profiles = s.profiles
        activeProfileID = s.activeProfileID
        enabled = s.enabled
        activateModifiers = NSEvent.ModifierFlags(rawValue: s.activateModifiers)
        displayDelay = s.displayDelay
        hideAfter = s.hideAfter
        hideOnRepeat = s.hideOnRepeat
        showOnActiveScreen = s.showOnActiveScreen
        switchByReleasing = s.switchByReleasing
        doublePressToggle = s.doublePressToggle
        switcherFilter = s.switcherFilter
        windowSwitcherEnabled = s.windowSwitcherEnabled
        windowSwitcherModifiers = NSEvent.ModifierFlags(rawValue: s.windowSwitcherModifiers)
        windowScope = WindowScope(rawValue: s.windowScope) ?? .allWindows
        includeMinimizedWindows = s.includeMinimizedWindows
        includeHiddenAppWindows = s.includeHiddenAppWindows
        windowSwitcherScale = s.windowSwitcherScale
        barSizeScale = s.barSizeScale
        barOpacity = s.barOpacity
        borderWidth = s.borderWidth
        verticalPosition = BarVerticalPosition(rawValue: s.verticalPosition) ?? .middle
        horizontalPosition = BarHorizontalPosition(rawValue: s.horizontalPosition) ?? .center
        silentApps = s.silentApps
        mruBundleIDs = s.mruBundleIDs
        usageCount = s.usageCount
        usageByDay = s.usageByDay
        welcomeShown = s.welcomeShown
        showStatusIcon = s.showStatusIcon
        autoUpdateCheck = s.autoUpdateCheck ?? true
    }

    // MARK: Profile mutations
    @discardableResult
    func addProfile(mode: AppMode) -> Profile {
        let order = (profiles.map(\.sortOrder).max() ?? -1) + 1
        let name: String
        switch mode {
        case .dock: name = "Dock"
        case .switcher: name = "Switcher"
        case .custom: name = "自定义配置 \(profiles.filter { $0.mode == .custom }.count + 1)"
        }
        let p = Profile(name: name, mode: mode, sortOrder: order)
        profiles.append(p)
        return p
    }

    func duplicate(_ profile: Profile) {
        var p = profile
        p.id = UUID()
        p.name = profile.name + " 副本"
        p.sortOrder = (profiles.map(\.sortOrder).max() ?? -1) + 1
        profiles.append(p)
    }

    func delete(_ profile: Profile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles.sorted { $0.sortOrder < $1.sortOrder }.first?.id
        }
    }

    func silentEntry(for bundleID: String) -> SilentEntry? {
        silentApps.first { $0.bundleID == bundleID }
    }

    func recordActivation(_ bundleID: String) {
        mruBundleIDs.removeAll { $0 == bundleID }
        mruBundleIDs.insert(bundleID, at: 0)
        if mruBundleIDs.count > 50 { mruBundleIDs = Array(mruBundleIDs.prefix(50)) }
        usageCount += 1
        let key = Self.dayFormatter.string(from: Date())
        usageByDay[key, default: 0] += 1
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
