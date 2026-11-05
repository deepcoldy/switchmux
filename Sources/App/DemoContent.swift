import AppKit

/// Neutral demo content for screenshots and the promo video
/// (SWITCHMUX_DEMO=1). Never active in normal use: the window switcher shows
/// made-up windows of stock Apple apps with drawn thumbnails instead of the
/// user's real (possibly private) windows.
enum DemoContent {
    static var isOn: Bool { ProcessInfo.processInfo.environment["SWITCHMUX_DEMO"] != nil }

    private struct DemoWindow {
        let app: String
        let path: String
        let title: String
        let accent: NSColor
        let dark: Bool
    }

    private static let windows: [DemoWindow] = [
        .init(app: "Safari", path: "/Applications/Safari.app", title: "SwitchMux — GitHub", accent: .systemBlue, dark: false),
        .init(app: "Notes", path: "/System/Applications/Notes.app", title: "发布清单", accent: .systemYellow, dark: false),
        .init(app: "Mail", path: "/System/Applications/Mail.app", title: "收件箱", accent: .systemBlue, dark: false),
        .init(app: "Safari", path: "/Applications/Safari.app", title: "Release notes · v1.2.0", accent: .systemBlue, dark: false),
        .init(app: "Calendar", path: "/System/Applications/Calendar.app", title: "本周", accent: .systemRed, dark: false),
        .init(app: "Terminal", path: "/System/Applications/Utilities/Terminal.app", title: "~/switchmux — zsh", accent: .systemGreen, dark: true),
        .init(app: "Music", path: "/System/Applications/Music.app", title: "最近播放", accent: .systemPink, dark: true),
        .init(app: "Finder", path: "/System/Library/CoreServices/Finder.app", title: "应用程序", accent: .systemBlue, dark: false),
        .init(app: "Preview", path: "/System/Applications/Preview.app", title: "design.pdf", accent: .systemOrange, dark: false),
        .init(app: "Freeform", path: "/System/Applications/Freeform.app", title: "灵感板", accent: .systemPurple, dark: false),
    ]

    static func windowItems(scope: WindowScope) -> [WindowItem] {
        let list = scope == .currentApp ? windows.filter { $0.app == "Safari" } : windows
        let current = NSRunningApplication.current
        return list.enumerated().compactMap { i, w in
            guard FileManager.default.fileExists(atPath: w.path) else { return nil }
            return WindowItem(windowID: CGWindowID(90_000 + i), pid: current.processIdentifier,
                              appName: w.app, bundleID: nil, title: w.title,
                              frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              isMinimized: false, isOnScreen: true, app: current,
                              icon: NSWorkspace.shared.icon(forFile: w.path), element: nil)
        }
    }

    /// A drawn window mock (title bar, sidebar, text lines) per demo window.
    static func thumbnail(for windowID: CGWindowID) -> NSImage? {
        let index = Int(windowID) - 90_000
        guard windows.indices.contains(index) else { return nil }
        let w = windows[index]
        let size = NSSize(width: 480, height: 300)
        return NSImage(size: size, flipped: true) { rect in
            let bg = w.dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            let fg = w.dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.09)
            bg.setFill(); rect.fill()
            // Title bar + traffic lights
            (w.dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.91, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 30).fill()
            for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: 44 + CGFloat(j) * 18, y: 10, width: 11, height: 11)).fill()
            }
            // Sidebar
            fg.setFill()
            NSRect(x: 0, y: 30, width: 110, height: rect.height - 30).fill()
            w.accent.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 46, width: 86, height: 14), xRadius: 4, yRadius: 4).fill()
            fg.setFill()
            for k in 0..<5 {
                NSBezierPath(roundedRect: NSRect(x: 12, y: 72 + CGFloat(k) * 22, width: 70 - CGFloat(k % 3) * 12, height: 10),
                             xRadius: 3, yRadius: 3).fill()
            }
            // Content: heading, accent block, text lines
            (w.dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.6)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 132, y: 48, width: 180, height: 16), xRadius: 4, yRadius: 4).fill()
            w.accent.withAlphaComponent(w.dark ? 0.55 : 0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: 132, y: 80, width: rect.width - 156, height: 74), xRadius: 8, yRadius: 8).fill()
            fg.setFill()
            for k in 0..<5 {
                let width = (rect.width - 156) * [1.0, 0.92, 0.97, 0.7, 0.85][k]
                NSBezierPath(roundedRect: NSRect(x: 132, y: 172 + CGFloat(k) * 22, width: width, height: 10),
                             xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }
}
