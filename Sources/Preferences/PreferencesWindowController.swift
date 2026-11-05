import AppKit
import SwiftUI

enum PrefsPane: String, CaseIterable, Identifiable {
    case general, apps, appBar, windowSwitcher, silent, usage, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .apps: return "应用"
        case .appBar: return "应用栏"
        case .windowSwitcher: return "窗口切换"
        case .silent: return "例外"
        case .usage: return "统计"
        case .about: return "关于"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .apps: return "square.grid.2x2"
        case .appBar: return "dock.rectangle"
        case .windowSwitcher: return "rectangle.on.rectangle.angled"
        case .silent: return "moon.zzz"
        case .usage: return "chart.bar.fill"
        case .about: return "info.circle"
        }
    }
}

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let toolbar = NSToolbar(identifier: "SwitchMuxPrefsToolbar")
    private var pane: PrefsPane = .apps
    private var hosting: NSHostingView<AnyView>?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "SwitchMux 设置"
        window.center()
        self.init(window: window)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        select(.apps)
    }

    static let size = NSSize(width: 760, height: 540)

    func showWindow(_ pane: PrefsPane? = nil) {
        if let pane { select(pane) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil as Any?)
        window?.makeKeyAndOrderFront(nil)
    }

    fileprivate func select(_ pane: PrefsPane) {
        self.pane = pane
        if pane != .apps { ShortcutRecorder.shared.cancel() }
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window?.title = pane.title

        let rootView: AnyView
        switch pane {
        case .general: rootView = AnyView(GeneralPane())
        case .apps: rootView = AnyView(AppsPane())
        case .appBar: rootView = AnyView(AppBarPane())
        case .windowSwitcher: rootView = AnyView(WindowSwitcherPane())
        case .silent: rootView = AnyView(SilentPane())
        case .usage: rootView = AnyView(UsagePane())
        case .about: rootView = AnyView(AboutPane())
        }
        let framed = AnyView(
            rootView
                .frame(width: Self.size.width, height: Self.size.height)
                .environmentObject(SettingsStore.shared)
        )
        let host = NSHostingView(rootView: framed)
        hosting?.removeFromSuperview()
        host.autoresizingMask = [.width, .height]
        let container = window!.contentView ?? {
            let c = NSView(frame: window!.contentLayoutRect)
            window!.contentView = c
            return c
        }()
        host.frame = container.bounds
        container.addSubview(host)
        hosting = host
    }
}

extension PreferencesWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PrefsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PrefsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PrefsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = PrefsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(switchPane(_:))
        item.isBordered = true
        return item
    }

    @objc private func switchPane(_ sender: NSToolbarItem) {
        guard let p = PrefsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(p)
    }

    /// Debug: select a pane programmatically.
    func smokeSelect(_ pane: PrefsPane) { select(pane) }

    /// Debug: dump the current pane content to a PNG.
    func smokeDumpPane(to path: String) {
        guard let view = window?.contentView else { return }
        NSLog("SMOKEPANE window=\(window?.frame ?? .zero) container=\(view.bounds) subviews=\(view.subviews.map(\.bounds))")
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
