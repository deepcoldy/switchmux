import AppKit
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A crashed earlier instance may have left system ⌘Tab disabled;
        // make sure it comes back however we exit.
        if ProcessInfo.processInfo.environment["SWITCHMUX_NO_HOTKEYS"] == nil {
            NativeCommandTab.forceRestore()
            NativeCommandTab.installCrashGuards()
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        _ = AppsMonitor.shared

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
                HotkeyController.shared.rebuildTap()
                if trusted { HotkeyController.shared.showToast("SwitchMux 已就绪") }
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

        // Auto-update checks (daily, with launch jitter); no UI unless a
        // downloadable release is found.
        UpdateChecker.shared.start()

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

        // Debug hook: SWITCHMUX_SMOKE_WINDOWS=/tmp/out.png renders the switcher.
        if let path = ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_WINDOWS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                WindowSwitcherController.shared.smokeShow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyController.shared.shutdown()
    }

    // Launching SwitchMux again (e.g. from Finder with no status icon) opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.showWindow()
        return true
    }
}
