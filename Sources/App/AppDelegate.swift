import AppKit
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item
        statusBar = StatusBarController()
        statusBar?.refresh()

        SettingsStore.shared.$showStatusIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.statusBar?.install(); self?.statusBar?.refresh() }
                else { self?.statusBar?.remove() }
            }
            .store(in: &cancellables)

        // Refresh App Bar chrome when apps launch / quit / activate / hide.
        AppsMonitor.shared.changePublisher
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                AppBarController.shared.reloadIfVisible()
            }
            .store(in: &cancellables)

        // Global hotkey (requires Accessibility / Input Monitoring permission).
        // The watcher polls TCC live: the tap is (re)built the instant access
        // is granted or re-granted — no app restart required.
        HotkeyController.shared.start()
        PermissionWatcher.shared.changePublisher
            .receive(on: RunLoop.main)
            .sink { trusted in
                if trusted {
                    HotkeyController.shared.rebuildTap()
                    HotkeyController.shared.showToast("SwitchMux 已就绪")
                } else {
                    HotkeyController.shared.rebuildTap()
                }
            }
            .store(in: &cancellables)
        PermissionWatcher.shared.start()
        if !PermissionWatcher.shared.trusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PermissionWatcher.shared.systemPrompt()
            }
        }

        // First-run welcome.
        if !SettingsStore.shared.welcomeShown {
            WelcomeWindowController.shared.showWindow()
        }

        // Debug hook: SWITCHMUX_KEYTEST=1 shows the bar via synthetic Option and
        // posts Option+1 from inside the (Accessibility-trusted) app process.
        if ProcessInfo.processInfo.environment["SWITCHMUX_KEYTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = .maskAlternate) {
                    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                    virtualKey: key, keyDown: down)!
                    e.flags = flags
                    e.post(tap: .cghidEventTap)
                }
                post(0x3A, down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { post(18, down: true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { post(18, down: false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { post(0x3A, down: false) }
            }
        }

        // Debug hook: SWITCHMUX_TRUST_CYCLE=1 simulates revoke→grant and logs
        // whether the event tap is rebuilt without restarting the app.
        if ProcessInfo.processInfo.environment["SWITCHMUX_TRUST_CYCLE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSLog("TRUSTCYCLE tap active at start: \(HotkeyController.shared.tapActive)")
                PermissionWatcher.shared.debugSimulateChange(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSLog("TRUSTCYCLE tap active after revoke: \(HotkeyController.shared.tapActive)")
                    PermissionWatcher.shared.debugSimulateChange(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSLog("TRUSTCYCLE tap active after grant: \(HotkeyController.shared.tapActive)")
                    }
                }
            }
        }

        // Debug hook: SWITCHMUX_SMOKE=/tmp/out.png shows the bar and rasterizes it.
        if let dumpPath = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AppBarController.shared.smokeShow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppBarController.shared.smokeDump(to: dumpPath)
                }
            }
        }

        // Debug hook: SWITCHMUX_SMOKE_PANES=/tmp/dir dumps every preferences pane.
        if let dir = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_PANES"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let prefs = PreferencesWindowController.shared
                prefs.showWindow()
                let panes = PrefsPane.allCases
                for (i, pane) in panes.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.9) {
                        prefs.smokeSelect(pane)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            prefs.smokeDumpPane(to: "\(dir)/pane-\(pane.rawValue).png")
                        }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_WELCOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WelcomeWindowController.shared.showWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    WelcomeWindowController.shared.smokeDump(to: "/tmp/mcap/panes/welcome.png")
                }
            }
        }

        // Debug hook: SWITCHMUX_WINTEST=1 verifies the Cmd-Tab chord: Cmd alone
        // and Cmd+C must not show the switcher; Cmd+Tab must.
        if ProcessInfo.processInfo.environment["SWITCHMUX_WINTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
                    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                    virtualKey: key, keyDown: down)!
                    e.flags = flags
                    e.post(tap: .cghidEventTap)
                }
                NSLog("WINTEST start visible=\(WindowSwitcherController.shared.isVisible)")
                post(0x37, down: true, flags: .maskCommand)        // Cmd down
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSLog("WINTEST cmd-only visible=\(WindowSwitcherController.shared.isVisible)")
                    post(8, down: true, flags: .maskCommand)        // C down (Cmd+C)
                    post(8, down: false, flags: .maskCommand)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSLog("WINTEST cmd+c visible=\(WindowSwitcherController.shared.isVisible)")
                    post(48, down: true, flags: .maskCommand)       // Tab down (Cmd+Tab)
                    post(48, down: false, flags: .maskCommand)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    NSLog("WINTEST cmd+tab visible=\(WindowSwitcherController.shared.isVisible) windows=\(WindowSwitcherController.shared.itemsCount)")
                    post(0x37, down: false)                          // Cmd up
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    NSLog("WINTEST after release visible=\(WindowSwitcherController.shared.isVisible)")
                }
            }
        }

        // Debug hook: SWITCHMUX_SMOKE_WINDOWS=/tmp/out.png renders the switcher.
        if let path = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_WINDOWS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WindowSwitcherController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    WindowSwitcherController.shared.smokeDump(to: path)
                }
            }
        }

        // Debug hook: SWITCHMUX_SMOKE_GUIDE=/tmp/out.png shows the floating
        // Accessibility drag guide and rasterizes it.
        if let path = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_GUIDE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                PermissionGuideController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    PermissionGuideController.shared.smokeDump(to: path)
                }
            }
        }

        if let one = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_PANE"],
           let pane = PrefsPane(rawValue: one) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let prefs = PreferencesWindowController.shared
                prefs.showWindow()
                prefs.smokeSelect(pane)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    prefs.smokeDumpPane(to: "/tmp/mcap/panes/single.png")
                }
            }
        }
    }

    // Launching SwitchMux again (e.g. from Finder with no status icon) opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.showWindow()
        return true
    }
}
