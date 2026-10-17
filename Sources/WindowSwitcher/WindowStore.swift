import AppKit
import ApplicationServices

/// One switchable window across applications.
struct WindowItem {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    let frame: CGRect          // Core Graphics global coords (top-left origin)
    let isMinimized: Bool
    let isOnScreen: Bool
    let app: NSRunningApplication
    let icon: NSImage
}

enum WindowStore {
    /// Snapshot windows for the requested scope. Accessibility is the
    /// authority for window identity: only AXStandardWindow windows (or windows
    /// with a close button) are kept, which excludes overlay/accessory windows
    /// that also appear in the Core Graphics window list.
    static func snapshot(scope: WindowScope, includeMinimized: Bool, includeHidden: Bool) -> [WindowItem] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        // CG metadata by window number.
        var cgMeta: [CGWindowID: [String: Any]] = [:]
        if let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for info in raw {
                guard let num = info[kCGWindowNumber as String] as? Int else { continue }
                cgMeta[CGWindowID(num)] = info
            }
        }

        var result: [WindowItem] = []

        for app in running {
            let pid = app.processIdentifier
            var axWindows: [AXUIElement] = []
            let axApp = AXUIElementCreateApplication(pid)
            var winsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
               let wins = winsRef as? [AXUIElement] {
                axWindows = wins.filter(isStandardWindow)
            }

            if axWindows.isEmpty {
                // AX unavailable: fall back to the CG list for this app.
                result.append(contentsOf: fallbackWindows(app: app, cgMeta: cgMeta,
                                                          scope: scope, frontPID: frontPID,
                                                          includeMinimized: includeMinimized,
                                                          includeHidden: includeHidden))
                continue
            }

            for window in axWindows {
                var cgid = CGWindowID(0)
                guard axWindowID(window, &cgid) else { continue }
                let meta = cgMeta[cgid]
                let onScreen = (meta?[kCGWindowIsOnscreen as String] as? Bool) ?? false
                var minimized = axBool(window, kAXMinimizedAttribute as CFString) ?? false
                // AX sometimes lags; cross-check CG (off-screen + no AX flag).
                if minimized == false && onScreen == false && app.isHidden == false {
                    // Could be other-Space or minimized; trust AX for standard windows.
                }

                if app.isHidden {
                    guard includeHidden else { continue }
                }
                if minimized {
                    guard includeMinimized else { continue }
                }
                if !onScreen && !minimized && !app.isHidden && scope != .allWindows {
                    continue // window on another Space
                }
                if scope == .currentApp, pid != frontPID { continue }
                if scope == .currentSpace, onScreen == false { continue }

                let title = (axString(window, kAXTitleAttribute as CFString))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? (app.localizedName ?? "")
                let frame = cgFrame(meta) ?? axFrame(window)
                result.append(WindowItem(
                    windowID: cgid, pid: pid,
                    appName: app.localizedName ?? "",
                    bundleID: app.bundleIdentifier,
                    title: title,
                    frame: frame,
                    isMinimized: minimized,
                    isOnScreen: onScreen,
                    app: app,
                    icon: app.icon ?? NSImage()
                ))
            }
        }

        return ordered(result)
    }

    // MARK: AX helpers
    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
              (roleRef as? String) == "AXWindow" else { return false }
        var subRef: CFTypeRef?
        let sub = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subRef) == .success
            ? (subRef as? String) : nil
        if sub == "AXStandardWindow" { return true }
        // Some standard windows omit the subrole but still have a close button.
        var closeRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeRef) == .success
    }

    private static let axGetWindow: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32 = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        let sym = dlsym(handle, "_AXUIElementGetWindow")
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32).self)
    }()

    private static func axWindowID(_ window: AXUIElement, _ id: inout CGWindowID) -> Bool {
        axGetWindow(window, &id) == 0 && id != 0
    }

    private static func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr, &v) == .success ? v as? String : nil
    }

    private static func axBool(_ element: AXUIElement, _ attr: CFString) -> Bool? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr, &v) == .success ? (v as? Bool) : nil
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var rect = CGRect.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let posValue = posRef, let sizeValue = sizeRef {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetType(posValue as! AXValue) == .cgPoint,
               AXValueGetType(sizeValue as! AXValue) == .cgSize,
               AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                rect = CGRect(origin: point, size: size)
            }
        }
        return rect
    }

    private static func cgFrame(_ meta: [String: Any]?) -> CGRect? {
        guard let b = meta?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: CG fallback (AX unavailable)
    private static func fallbackWindows(app: NSRunningApplication, cgMeta: [CGWindowID: [String: Any]],
                                        scope: WindowScope, frontPID: pid_t?,
                                        includeMinimized: Bool, includeHidden: Bool) -> [WindowItem] {
        var out: [WindowItem] = []
        for (id, info) in cgMeta {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { continue }
            guard let frame = cgFrame(info), frame.width > 120, frame.height > 80 else { continue }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if scope == .currentApp, pid != frontPID { continue }
            if scope == .currentSpace, onScreen == false { continue }
            if !onScreen, scope != .allWindows { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (app.localizedName ?? "")
            out.append(WindowItem(
                windowID: id, pid: pid,
                appName: app.localizedName ?? "", bundleID: app.bundleIdentifier,
                title: title, frame: frame,
                isMinimized: false, isOnScreen: onScreen,
                app: app, icon: app.icon ?? NSImage()))
        }
        return out
    }

    // MARK: Ordering (frontmost app, then MRU, then launch date)
    private static func ordered(_ items: [WindowItem]) -> [WindowItem] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mru = SettingsStore.shared.mruBundleIDs
        func rank(_ item: WindowItem) -> Int {
            if item.pid == frontPID { return -2 }
            if let bid = item.bundleID, let i = mru.firstIndex(of: bid) { return i }
            return 1_000_000
        }
        // Items arrive grouped by app in AX order; remember first index per app.
        var appOrder: [pid_t: Int] = [:]
        for (i, item) in items.enumerated() where appOrder[item.pid] == nil {
            appOrder[item.pid] = i
        }
        return items.enumerated().sorted { lhs, rhs in
            let ra = rank(lhs.element); let rb = rank(rhs.element)
            if ra != rb { return ra < rb }
            let ao = appOrder[lhs.element.pid] ?? 0
            let bo = appOrder[rhs.element.pid] ?? 0
            if ao != bo { return ao < bo }
            return lhs.offset < rhs.offset   // stable within-app (AX z-order)
        }.map(\.element)
    }
}
