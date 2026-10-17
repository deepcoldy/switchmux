import AppKit

/// Menu-bar status item: profile switcher, enable toggle, silent-mode shortcuts,
/// preferences and quit.
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var silentMenuItem: NSMenuItem?

    override init() {
        super.init()
        if SettingsStore.shared.showStatusIcon { install() }
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "option", accessibilityDescription: "SwitchMux")
        item.button?.image?.isTemplate = true
        item.button?.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func remove() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    func refresh() {
        statusItem?.button?.appearsDisabled = !SettingsStore.shared.enabled
    }

    private func buildMenu(_ menu: NSMenu) {
        let settings = SettingsStore.shared
        menu.removeAllItems()

        // Profile switcher
        let profileMenu = NSMenu()
        for p in settings.profiles.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let item = NSMenuItem(title: p.name, action: #selector(switchProfile(_:)), keyEquivalent: "")
            item.target = self
            item.state = p.id == settings.activeProfile.id ? .on : .off
            item.representedObject = p.id.uuidString
            profileMenu.addItem(item)
        }
        let profileItem = NSMenuItem(title: "配置", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        let enabledItem = NSMenuItem(title: "启用 SwitchMux",
                                     action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = settings.enabled ? .on : .off
        menu.addItem(enabledItem)

        // Silent-mode toggle for the current frontmost app
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier {
            let name = front.localizedName ?? "当前应用"
            let isSilent = settings.silentEntry(for: bid) != nil
            let title = isSilent ? "将「\(name)」移出静默模式" : "将「\(name)」加入静默模式"
            let item = NSMenuItem(title: title, action: #selector(toggleSilentForFrontmost), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Surface a missing/revoked Accessibility grant (also happens after an
        // ad-hoc rebuild, whose cdhash invalidates the prior TCC entry).
        if !PermissionWatcher.shared.trusted {
            let warn = NSMenuItem(title: "⚠️ 辅助功能未授权（热键不可用）",
                                  action: #selector(fixPermission), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let prefsItem = NSMenuItem(title: "设置…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let welcomeItem = NSMenuItem(title: "欢迎页", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 SwitchMux", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func switchProfile(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        SettingsStore.shared.activeProfileID = id
    }

    @objc private func toggleEnabled() {
        SettingsStore.shared.enabled.toggle()
        HotkeyController.shared.announceEnabledState()
    }

    @objc private func toggleSilentForFrontmost() {
        let settings = SettingsStore.shared
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier else { return }
        if let existing = settings.silentEntry(for: bid) {
            settings.silentApps.removeAll { $0.id == existing.id }
        } else {
            settings.silentApps.append(SilentEntry(
                bundleID: bid,
                name: front.localizedName ?? bid
            ))
        }
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func fixPermission() {
        PrefsSupport.guideToAccessibility()
    }

    @objc private func showWelcome() {
        WelcomeWindowController.shared.showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        buildMenu(menu)
    }
}
