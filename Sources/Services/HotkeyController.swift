import AppKit
import ApplicationServices

/// State machine for BOTH activation contexts:
/// - App Bar hotkey (default ⌥ Option): hold → icon bar, digits to switch.
/// - Window switcher hotkey (default ⌘ Command): press Tab while holding the
///   modifier → thumbnail grid; Tab/arrows/digits navigate, release activates.
/// Double-pressing the App Bar hotkey toggles enablement temporarily.
final class HotkeyController {
    static let shared = HotkeyController()

    private enum Context { case bar, windowSwitcher }

    private let tap = HotkeyEventTap()
    private var displayWorkItem: DispatchWorkItem?
    private var lastReleaseAt: Date = .distantPast
    private var lastPressAt: Date = .distantPast
    private var toggleSuppressed = false
    private var active: Context?

    // Window-switcher quick-chord arbitration: a short Tab press is handed
    // back to the system (native ⌘Tab), holding it past the threshold shows
    // our thumbnail grid. Kept short: a typical fast tap is 50–130 ms.
    private let triggerKeyCode: CGKeyCode = 48 // Tab
    private let holdThreshold: TimeInterval = 0.15
    private var triggerWorkItem: DispatchWorkItem?
    private var triggerArmed = false
    private var triggerFlags: NSEvent.ModifierFlags = []
    private var nativePassthrough = false

    private let relevantMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    private let doublePressWindow: TimeInterval = 0.35

    private init() {}

    func start() {
        tap.onFlagsChanged = { [weak self] flags in self?.handleFlags(flags) }
        tap.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        tap.onKeyUp = { [weak self] event in self?.handleKeyUp(event) ?? false }
        ensureTap()
    }

    func ensureTap() {
        guard !tap.isActive else { return }
        guard AXIsProcessTrusted() else { return }
        tap.start()
    }

    func rebuildTap() {
        tap.stop()
        ensureTap()
    }

    var tapActive: Bool { tap.isActive }

    private var barMask: NSEvent.ModifierFlags {
        let mask = SettingsStore.shared.activateModifiers.intersection(relevantMask)
        return mask.isEmpty ? .option : mask
    }
    private var windowMask: NSEvent.ModifierFlags {
        SettingsStore.shared.windowSwitcherModifiers.intersection(relevantMask)
    }

    // MARK: Flags
    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection(relevantMask)

        if active == nil {
            if SettingsStore.shared.windowSwitcherEnabled && !windowMask.isEmpty && relevant == windowMask
                && windowMask != barMask {
                begin(.windowSwitcher)
                return
            }
            if relevant == barMask {
                beginBar()
                return
            }
        } else {
            // While held, extra modifiers are allowed as long as the context
            // mask stays down.
            if active == .windowSwitcher, relevant.contains(windowMask) { return }
            if active == .bar, relevant.contains(barMask) { return }
            release()
        }
    }

    private func begin(_ context: Context) {
        active = context
        switch context {
        case .windowSwitcher:
            // Chord model: merely holding the modifier does nothing
            // (so ⌘C, ⌘V, … keep working). The overlay appears only when the
            // trigger key (Tab) is pressed while the modifier is held.
            break
        case .bar:
            break
        }
    }

    private func beginBar() {
        active = .bar
        guard !toggleSuppressed else { return }

        let now = Date()
        if SettingsStore.shared.doublePressToggle,
           now.timeIntervalSince(lastReleaseAt) < doublePressWindow,
           now.timeIntervalSince(lastPressAt) > 0.05 {
            SettingsStore.shared.enabled.toggle()
            toggleSuppressed = true
            announceEnabledState()
            return
        }
        lastPressAt = now

        guard SettingsStore.shared.enabled else { return }
        if let bid = AppsMonitor.shared.frontmost?.bundleIdentifier,
           let entry = SettingsStore.shared.silentEntry(for: bid),
           entry.hideBar {
            return
        }

        let delay = SettingsStore.shared.displayDelay
        if delay < 0 { return } // "Never display" — blind shortcuts only.

        let work = DispatchWorkItem { AppBarController.shared.show() }
        displayWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func release() {
        displayWorkItem?.cancel()
        displayWorkItem = nil
        cancelTriggerArm()
        let wasPassthrough = nativePassthrough
        nativePassthrough = false
        toggleSuppressed = false
        lastReleaseAt = Date()
        switch active {
        case .bar:
            if AppBarController.shared.isVisible {
                AppBarController.shared.hide(activateHovered: SettingsStore.shared.switchByReleasing)
            }
        case .windowSwitcher:
            // Only finish our overlay if it actually appeared. A passthrough
            // chord (quick release) must do nothing here — the native switcher
            // handles activation on key-up itself.
            if WindowSwitcherController.shared.isVisible && !wasPassthrough {
                WindowSwitcherController.shared.finish(activate: true)
            }
        case .none:
            break
        }
        active = nil
    }

    // MARK: Window-switcher trigger arbitration

    private func armTrigger(_ event: NSEvent) {
        guard !triggerArmed else { return }
        triggerArmed = true
        nativePassthrough = false
        triggerFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let forward = !event.modifierFlags.contains(.shift)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.triggerArmed else { return }
            self.triggerArmed = false
            self.triggerWorkItem = nil
            WindowSwitcherController.shared.present(forward: forward)
        }
        triggerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func cancelTriggerArm() {
        triggerWorkItem?.cancel()
        triggerWorkItem = nil
        triggerArmed = false
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard active == .windowSwitcher, event.keyCode == triggerKeyCode else { return false }
        // Quick release while still in the arming window → forward the whole
        // chord to the native switcher, then tear our context down quietly.
        if triggerArmed {
            cancelTriggerArm()
            nativePassthrough = true
            // Post from OUTSIDE this tap callback (next runloop turn): events
            // posted synchronously inside a tap callback get mis-ordered against
            // the swallowed physical event and the Dock never sees the chord.
            DispatchQueue.main.async { [weak self] in self?.forwardTriggerToSystem() }
            DispatchQueue.main.async { [weak self] in self?.release() }
            return true
        }
        return false
    }

    /// Re-posts the swallowed Tab chord to the native switcher: key-down now,
    /// key-up ~30 ms later like a real physical tap.
    private func forwardTriggerToSystem() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cgFlags = CGEventFlags(rawValue: UInt64(triggerFlags.rawValue))
        func post(_ down: Bool) {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: triggerKeyCode, keyDown: down) else { return }
            cg.setIntegerValueField(.eventSourceUserData, value: HotkeyEventTap.syntheticUserData)
            cg.flags = cgFlags
            cg.post(tap: .cghidEventTap)
        }
        post(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { post(false) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch active {
        case .windowSwitcher:
            // Overlay not up yet: the trigger key starts the hold-or-forward
            // arbitration and is swallowed either way (quick release forwards a
            // synthetic copy instead). Every other key passes through untouched
            // (⌘C/⌘V/⌘` and the native switcher all keep working).
            if !WindowSwitcherController.shared.isVisible {
                if event.keyCode == triggerKeyCode {
                    armTrigger(event)
                    return true
                }
                return false
            }
            return WindowSwitcherController.shared.handleKey(event)
        case .bar:
            return AppBarController.shared.handleKeyDown(event)
        case .none:
            return false
        }
    }

    // MARK: Toast
    private var toast: ToastPanel?

    func announceEnabledState() {
        let text = SettingsStore.shared.enabled ? "SwitchMux 已启用" : "SwitchMux 已暂停"
        toast?.orderOut(nil)
        let panel = ToastPanel(text: text)
        toast = panel
        panel.present()
    }

    func showToast(_ text: String) {
        toast?.orderOut(nil)
        let panel = ToastPanel(text: text)
        toast = panel
        panel.present()
    }
}
