import AppKit
import ApplicationServices

/// AX-based window actions (raise a specific window, close, minimize) plus
/// app-level hide / terminate, bound to the switcher's keyboard actions.
enum WindowActions {
    static func activate(_ item: WindowItem) {
        let app = item.app
        app.unhide()
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        raiseWindow(pid: item.pid, windowID: item.windowID)
    }

    static func hideApp(_ item: WindowItem) {
        item.app.hide()
    }

    static func quitApp(_ item: WindowItem) {
        item.app.terminate()
    }

    static func closeWindow(_ item: WindowItem) {
        pressButton(kAXCloseButtonAttribute, pid: item.pid, windowID: item.windowID)
    }

    static func minimizeWindow(_ item: WindowItem) {
        pressButton(kAXMinimizeButtonAttribute, pid: item.pid, windowID: item.windowID)
    }

    // MARK: AX plumbing
    private static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        for window in windows {
            var numRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &numRef) == .success,
                  let num = numRefRef(numRef) else { continue }
            if num == windowID { return window }
        }
        return nil
    }

    private static func numRefRef(_ ref: CFTypeRef?) -> CGWindowID? {
        guard let ref else { return nil }
        if let n = ref as? NSNumber { return CGWindowID(n.uint32Value) }
        return nil
    }

    private static func raiseWindow(pid: pid_t, windowID: CGWindowID) {
        guard let window = axWindow(pid: pid, windowID: windowID) else { return }
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimized = minimizedRef as? Bool, minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, "AXRaise" as CFString)
    }

    private static func pressButton(_ attribute: String, pid: pid_t, windowID: CGWindowID) {
        guard let window = axWindow(pid: pid, windowID: windowID) else { return }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &buttonRef) == .success else { return }
        let button = buttonRef as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}
