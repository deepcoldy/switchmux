import AppKit
import ApplicationServices

/// One switchable window.
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
    /// Live AX element (nil when the app doesn't expose AX).
    let element: AXUIElement?
}

enum WindowStore {
    struct Query {
        var scope: WindowScope
        var includeMinimized: Bool
        var includeHidden: Bool
        /// Captured on the main thread before going to the background.
        var frontPID: pid_t?
        var mru: [String]
    }

    static func query(scope: WindowScope) -> Query {
        let s = SettingsStore.shared
        return Query(scope: scope,
                     includeMinimized: s.includeMinimizedWindows,
                     includeHidden: s.includeHiddenAppWindows,
                     frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                     mru: s.mruBundleIDs)
    }

    /// Enumerates windows. Safe to call off the main thread (and it should be:
    /// AX calls block on busy apps; each app gets a 0.25 s messaging timeout
    /// and apps are queried in parallel so one hung app can't stall the rest).
    ///
    /// Order = most recently used first: on-screen windows in WindowServer
    /// z-order (which is focus order), then off-screen ones (other Spaces,
    /// minimized, hidden) by app recency.
    static func snapshot(_ q: Query) -> [WindowItem] {
        if DemoContent.isOn { return DemoContent.windowItems(scope: q.scope) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated }
        if q.scope == .currentApp {
            apps = apps.filter { $0.processIdentifier == q.frontPID }
        }

        // CG metadata by window number, plus the on-screen z-order.
        var cgMeta: [CGWindowID: [String: Any]] = [:]
        var pidsWithWindows = Set<pid_t>()
        if let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for info in raw {
                guard let num = info[kCGWindowNumber as String] as? Int,
                      (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
                cgMeta[CGWindowID(num)] = info
                if let pid = info[kCGWindowOwnerPID as String] as? pid_t { pidsWithWindows.insert(pid) }
            }
        }
        var zOrder: [CGWindowID: Int] = [:]
        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] {
            for (i, info) in onScreen.enumerated() {
                if let num = info[kCGWindowNumber as String] as? Int { zOrder[CGWindowID(num)] = i }
            }
        }

        // Apps without any normal-layer window can't contribute; skip their AX round trip.
        apps = apps.filter { pidsWithWindows.contains($0.processIdentifier) }

        var perApp = [[WindowItem]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let items = windows(of: apps[i], q: q, cgMeta: cgMeta)
            lock.lock(); perApp[i] = items; lock.unlock()
        }
        let all = perApp.flatMap { $0 }

        func appRank(_ item: WindowItem) -> Int {
            if item.pid == q.frontPID { return -1 }
            if let bid = item.bundleID, let i = q.mru.firstIndex(of: bid) { return i }
            return Int.max / 2
        }
        return all.enumerated().sorted { a, b in
            let za = zOrder[a.element.windowID], zb = zOrder[b.element.windowID]
            switch (za, zb) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let ra = appRank(a.element), rb = appRank(b.element)
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
        }.map(\.element)
    }

    private static func windows(of app: NSRunningApplication, q: Query,
                                cgMeta: [CGWindowID: [String: Any]]) -> [WindowItem] {
        if app.isHidden && !q.includeHidden { return [] }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var winsRef: CFTypeRef?
        let axOK = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success
        let axWindows = (winsRef as? [AXUIElement]) ?? []
        if !axOK {
            return fallbackWindows(app: app, q: q, cgMeta: cgMeta)
        }

        var out: [WindowItem] = []
        for window in axWindows where AX.isStandardWindow(window) {
            let wid = PrivateAPI.windowID(of: window)
            guard wid != 0 else { continue }
            let meta = cgMeta[wid]
            let onScreen = (meta?[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let minimized = AX.bool(window, kAXMinimizedAttribute)
            if minimized && !q.includeMinimized { continue }
            // Off-screen, not minimized, app not hidden → on another Space.
            let otherSpace = !onScreen && !minimized && !app.isHidden
            // A hidden app's windows are off-screen on every Space, so their
            // Space can't be told; keep them out of the current-Space scope.
            if q.scope == .currentSpace && (otherSpace || minimized || app.isHidden) { continue }

            let title = AX.string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                ?? (app.localizedName ?? "")
            out.append(WindowItem(
                windowID: wid, pid: pid,
                appName: app.localizedName ?? "",
                bundleID: app.bundleIdentifier,
                title: title,
                frame: cgFrame(meta) ?? axFrame(window),
                isMinimized: minimized,
                isOnScreen: onScreen,
                app: app,
                icon: app.icon ?? NSImage(),
                element: window))
        }
        return out
    }

    // MARK: CG fallback (app doesn't answer AX)
    private static func fallbackWindows(app: NSRunningApplication, q: Query,
                                        cgMeta: [CGWindowID: [String: Any]]) -> [WindowItem] {
        var out: [WindowItem] = []
        for (id, info) in cgMeta {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier else { continue }
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let frame = cgFrame(info), frame.width > 120, frame.height > 80 else { continue }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            if q.scope == .currentSpace && !onScreen { continue }
            // Without AX we can't tell minimized from other-Space; only keep visible ones
            // unless the user wants everything.
            if !onScreen && q.scope != .allWindows { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (app.localizedName ?? "")
            out.append(WindowItem(
                windowID: id, pid: pid,
                appName: app.localizedName ?? "", bundleID: app.bundleIdentifier,
                title: title, frame: frame,
                isMinimized: false, isOnScreen: onScreen,
                app: app, icon: app.icon ?? NSImage(), element: nil))
        }
        return out
    }

    // MARK: Geometry
    private static func axFrame(_ window: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func cgFrame(_ meta: [String: Any]?) -> CGRect? {
        guard let dict = meta?[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
    }
}
