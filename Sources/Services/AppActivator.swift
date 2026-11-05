import AppKit
import ApplicationServices

/// Launches / activates / hides applications — the App Bar's switching actions.
enum AppActivator {
    /// Serial queue for AX + WindowServer calls, which can block on a busy app.
    static let queue = DispatchQueue(label: "SwitchMux.activation", qos: .userInteractive)

    enum Result { case launched, activated, hidden }

    /// Not running → launch. Frontmost → hide (if allowed). Hidden → unhide.
    /// Otherwise bring its frontmost window forward.
    @discardableResult
    static func trigger(_ slot: Slot, allowHide: Bool) -> Result {
        guard let app = AppsMonitor.shared.runningApp(for: (slot.url, slot.bundleID)) else {
            open(slot.url)
            return .launched
        }
        if app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            if allowHide {
                app.hide()
                return .hidden
            }
            return .activated
        }
        activate(app, fallbackURL: slot.url)
        return .activated
    }

    static func activate(_ app: NSRunningApplication, fallbackURL: URL?) {
        if app.isHidden { app.unhide() }
        let pid = app.processIdentifier
        queue.async {
            if let window = frontWindow(pid: pid) {
                if PrivateAPI.focusWindow(pid: pid, windowID: window.id, allWindows: true) {
                    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                    return
                }
            }
            // No usable window (or private API missing): behave like a Dock
            // click — Launch Services activates and sends a "reopen", which
            // restores a minimized window or opens a new one.
            DispatchQueue.main.async {
                if let url = fallbackURL ?? app.bundleURL {
                    open(url)
                } else {
                    app.activate(options: [.activateAllWindows])
                }
            }
        }
    }

    private static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// The app's focused (or main, or first visible standard) window.
    private static func frontWindow(pid: pid_t) -> (element: AXUIElement, id: CGWindowID)? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr as CFString, &ref) == .success,
               let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                let el = ref as! AXUIElement
                let id = PrivateAPI.windowID(of: el)
                if id != 0, !AX.bool(el, kAXMinimizedAttribute) { return (el, id) }
            }
        }
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement] {
            for el in wins where AX.isStandardWindow(el) && !AX.bool(el, kAXMinimizedAttribute) {
                let id = PrivateAPI.windowID(of: el)
                if id != 0 { return (el, id) }
            }
        }
        return nil
    }
}

/// Small Accessibility helpers shared by the window code.
enum AX {
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? (v as? Bool ?? false) : false
    }

    static func isStandardWindow(_ el: AXUIElement) -> Bool {
        guard string(el, kAXRoleAttribute) == kAXWindowRole else { return false }
        let sub = string(el, kAXSubroleAttribute)
        if sub == kAXStandardWindowSubrole { return true }
        if sub == kAXDialogSubrole || sub == kAXFloatingWindowSubrole || sub == kAXSystemDialogSubrole { return false }
        // Some standard windows omit the subrole but still have a close button.
        var close: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &close) == .success
    }
}
