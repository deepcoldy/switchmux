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

    private let relevantMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    private let doublePressWindow: TimeInterval = 0.35

    private init() {}

    func start() {
        tap.onFlagsChanged = { [weak self] flags in self?.handleFlags(flags) }
        tap.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
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
        toggleSuppressed = false
        lastReleaseAt = Date()
        switch active {
        case .bar:
            if AppBarController.shared.isVisible {
                AppBarController.shared.hide(activateHovered: SettingsStore.shared.switchByReleasing)
            }
        case .windowSwitcher:
            WindowSwitcherController.shared.finish(activate: true)
        case .none:
            break
        }
        active = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch active {
        case .windowSwitcher:
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
