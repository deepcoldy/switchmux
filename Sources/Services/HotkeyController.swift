import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

/// Coordinates every global shortcut:
/// - App Bar: hold the activation modifier (default ⌥) → icon bar; bound keys switch apps.
/// - Window switcher: ⌘Tab (all windows) and ⌥` (current app's windows),
///   registered as Carbon hotkeys; releasing the modifier activates the selection.
///
/// All state lives on the main thread. The event tap (own thread) only routes.
final class HotkeyController {
    static let shared = HotkeyController()

    private enum Trigger: Int {
        case allForward, allBackward, appForward, appBackward
    }

    private let tap = HotkeyEventTap()
    private var cancellables = Set<AnyCancellable>()
    private var configSignature = ""

    // App Bar hold state
    private var barHeld = false
    private var barPressAt: CFAbsoluteTime = 0
    private var lastCleanTapAt: CFAbsoluteTime = 0
    private var toggleSuppressed = false
    private var displayWork: DispatchWorkItem?

    // Window switcher session
    private var sessionMask: NSEvent.ModifierFlags?

    /// Fallback for missed flagsChanged events (secure input, tap hiccups):
    /// while anything is held we poll the real modifier state.
    private var pollTimer: Timer?

    private let doublePressWindow: CFTimeInterval = 0.35
    private let cleanTapMaxDuration: CFTimeInterval = 0.3

    private var hotkeysDisabledByEnv: Bool {
        ProcessInfo.processInfo.environment["SWITCHMUX_NO_HOTKEYS"] != nil
    }

    private init() {}

    // MARK: Setup
    func start() {
        tap.onFlagsChanged = { [weak self] flags, time in self?.handleFlags(flags, at: time) }
        tap.onBarKey = { [weak self] code in self?.handleBarKey(code) }
        tap.onSessionKey = { code, flags in WindowSwitcherController.shared.handleKey(code, flags: flags) }
        tap.onFallbackTrigger = { [weak self] raw in
            if let t = Trigger(rawValue: raw) { self?.fire(t) }
        }
        WindowSwitcherController.shared.onSessionEnded = { [weak self] in self?.sessionEndedByUI() }

        SettingsStore.shared.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reconfigureIfNeeded() }
            .store(in: &cancellables)
        AppsMonitor.shared.changePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateBarRouting() }
            .store(in: &cancellables)

        rebuildTap()
    }

    func rebuildTap() {
        tap.stop()
        if !hotkeysDisabledByEnv && AXIsProcessTrusted() { tap.start() }
        configSignature = ""
        reconfigureIfNeeded()
    }

    var tapActive: Bool { tap.isActive }

    /// Restores system ⌘Tab; called on quit.
    func shutdown() {
        CarbonHotkeys.shared.unregisterAll()
        tap.stop()
        NativeCommandTab.shutdown()
    }

    private var barMask: NSEvent.ModifierFlags {
        let m = SettingsStore.shared.activateModifiers.intersection(KeyChord.relevant)
        return m.isEmpty ? .option : m
    }

    /// Re-registers hotkeys only when a setting that affects them changed
    /// (usage counters etc. also publish changes and must not churn this).
    private func reconfigureIfNeeded() {
        let s = SettingsStore.shared
        let signature = [
            "\(tap.isActive)", "\(s.windowSwitcherEnabled)", s.windowSwitcherModifier.rawValue,
            "\(s.appWindowSwitcherEnabled)", s.appWindowSwitcherModifier.rawValue, "\(KeyCodes.keyAboveTab)",
        ].joined(separator: "|")
        if signature != configSignature {
            configSignature = signature
            registerSwitcherHotkeys()
        }
        updateBarRouting()
    }

    private var carbonChords = Set<KeyChord>()
    private var fallbackTriggers: [KeyChord: Int] = [:]

    private func registerSwitcherHotkeys() {
        let s = SettingsStore.shared
        CarbonHotkeys.shared.unregisterAll()
        carbonChords = []
        fallbackTriggers = [:]

        func bind(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags, _ trigger: Trigger) {
            let chord = KeyChord(keyCode, mods)
            if CarbonHotkeys.shared.register(keyCode: keyCode, modifiers: mods, action: { [weak self] in
                self?.fire(trigger)
            }) {
                carbonChords.insert(chord)
            } else {
                fallbackTriggers[chord] = trigger.rawValue
            }
        }

        // Everything requires the tap (Accessibility): without it we could not
        // see the modifier release nor raise windows, so leave the system alone.
        let active = tap.isActive
        if active && s.windowSwitcherEnabled {
            let m = s.windowSwitcherModifier.flags
            bind(KeyCodes.tab, m, .allForward)
            bind(KeyCodes.tab, m.union(.shift), .allBackward)
        }
        if active && s.appWindowSwitcherEnabled {
            let m = s.appWindowSwitcherModifier.flags
            // Only the physical key above Tab: on ISO keyboards that's § (10)
            // and 50 is the extra key next to left Shift, which must stay typable.
            for code in [KeyCodes.keyAboveTab] {
                bind(code, m, .appForward)
                bind(code, m.union(.shift), .appBackward)
            }
        }
        // ⌘Tab is consumed by the Dock before any app hotkey, so owning it
        // means turning the native one off (restored on quit / when disabled).
        let ownsCommandTab = active && s.windowSwitcherEnabled && s.windowSwitcherModifier == .command
        // Dev / smoke runs (SWITCHMUX_NO_HOTKEYS) never touch the global state.
        if !hotkeysDisabledByEnv { NativeCommandTab.setNativeEnabled(!ownsCommandTab) }
    }

    private func updateBarRouting() {
        if !hotkeysDisabledByEnv { NativeCommandTab.reassert() }
        let s = SettingsStore.shared
        let mask = barMask
        let reserved = carbonChords.union(fallbackTriggers.keys)
        let codes = Set(s.apps.compactMap(\.triggerKeyCode))
            .filter { !reserved.contains(KeyChord($0, mask)) }
        var keysEnabled = s.enabled
        if let bid = AppsMonitor.shared.frontmost?.bundleIdentifier,
           let entry = s.silentEntry(for: bid), entry.disableShortcuts {
            keysEnabled = false
        }
        let carbon = carbonChords, fallback = fallbackTriggers
        tap.updateRouting { r in
            r.barMask = mask
            r.barKeyCodes = codes
            r.barKeysEnabled = keysEnabled
            r.carbonChords = carbon
            r.fallbackTriggers = fallback
        }
    }

    // MARK: Modifier state
    /// `time` is when the change physically happened (tap thread clock), so
    /// clean-tap detection isn't fooled by main-thread lag.
    private func handleFlags(_ flags: NSEvent.ModifierFlags, at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        let relevant = flags.intersection(KeyChord.relevant)

        if let mask = sessionMask, !relevant.contains(mask) {
            endSession(activate: true)
        }
        if barHeld {
            if !relevant.contains(barMask) { barReleased(at: time) }
        } else if relevant == barMask && sessionMask == nil {
            barPressed(at: time)
        }
        updatePolling()
    }

    private func updatePolling() {
        let needed = barHeld || sessionMask != nil
        if needed, pollTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
                self?.handleFlags(NSEvent.ModifierFlags(rawValue: UInt(raw)))
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needed, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    // MARK: App Bar
    private func barPressed(at now: CFAbsoluteTime) {
        let s = SettingsStore.shared
        barHeld = true
        barPressAt = now

        // Double-tap of the bare modifier toggles SwitchMux. Only clean taps
        // count (no key pressed in between), so ⌥1 … ⌥2 in quick succession
        // no longer pauses the app by accident.
        if s.doublePressToggle && now - lastCleanTapAt < doublePressWindow {
            lastCleanTapAt = 0
            toggleSuppressed = true
            s.enabled.toggle()
            announceEnabledState()
            return
        }
        guard s.enabled else { return }
        if let bid = AppsMonitor.shared.frontmost?.bundleIdentifier,
           let entry = s.silentEntry(for: bid), entry.hideBar {
            return
        }
        let delay = s.displayDelay
        guard delay >= 0 else { return } // "never": blind shortcuts only

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.barHeld, self.sessionMask == nil else { return }
            AppBarController.shared.show()
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func barReleased(at now: CFAbsoluteTime) {
        barHeld = false
        displayWork?.cancel()
        displayWork = nil
        let clean = !toggleSuppressed
            && tap.lastKeyDown < barPressAt
            && now - barPressAt < cleanTapMaxDuration
        lastCleanTapAt = clean ? now : 0
        toggleSuppressed = false
        if AppBarController.shared.isVisible {
            AppBarController.shared.hide(activateHovered: SettingsStore.shared.switchByReleasing)
        }
    }

    private func handleBarKey(_ keyCode: UInt16) {
        AppBarController.shared.triggerKey(keyCode)
    }

    // MARK: Window switcher
    private func fire(_ trigger: Trigger) {
        let s = SettingsStore.shared
        switch trigger {
        case .allForward, .allBackward:
            beginOrStep(scope: s.windowScope, mask: s.windowSwitcherModifier.flags,
                        forward: trigger == .allForward)
        case .appForward, .appBackward:
            beginOrStep(scope: .currentApp, mask: s.appWindowSwitcherModifier.flags,
                        forward: trigger == .appForward)
        }
    }

    private func beginOrStep(scope: WindowScope, mask: NSEvent.ModifierFlags, forward: Bool) {
        if sessionMask != nil {
            WindowSwitcherController.shared.step(forward: forward)
            return
        }
        // The switcher takes over from a pending / visible App Bar
        // (e.g. ⌥ held for the bar, then ` pressed).
        displayWork?.cancel()
        displayWork = nil
        if AppBarController.shared.isVisible { AppBarController.shared.hide(activateHovered: false) }

        sessionMask = mask
        tap.updateRouting { $0.sessionActive = true }
        WindowSwitcherController.shared.beginSession(scope: scope, forward: forward)
        updatePolling()

        // The hotkey may have been delivered late (main thread was busy) after
        // the modifier was already let go: settle immediately.
        let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
        handleFlags(NSEvent.ModifierFlags(rawValue: UInt(raw)))
    }

    private func endSession(activate: Bool) {
        guard sessionMask != nil else { return }
        sessionMask = nil
        tap.updateRouting { $0.sessionActive = false }
        WindowSwitcherController.shared.endSession(activate: activate)
    }

    private func sessionEndedByUI() {
        sessionMask = nil
        tap.updateRouting { $0.sessionActive = false }
        updatePolling()
    }

    // MARK: Toast
    private var toast: ToastPanel?

    func announceEnabledState() {
        showToast(SettingsStore.shared.enabled ? "SwitchMux 应用栏已启用" : "SwitchMux 应用栏已暂停")
    }

    func showToast(_ text: String) {
        toast?.orderOut(nil)
        let panel = ToastPanel(text: text)
        toast = panel
        panel.present()
    }
}
