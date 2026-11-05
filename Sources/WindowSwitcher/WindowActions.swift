import AppKit
import ApplicationServices

/// Window-level actions for the switcher: focus a specific window, close,
/// minimize, plus app-level hide / quit.
///
/// The old implementation looked windows up through an "AXWindowNumber"
/// attribute that most apps don't implement, so raise / close / minimize
/// silently did nothing for them. Items now carry their AX element and the
/// real CGWindowID (via _AXUIElementGetWindow).
enum WindowActions {
    static func activate(_ item: WindowItem) {
        if item.app.isHidden { item.app.unhide() }
        let pid = item.pid, wid = item.windowID, element = item.element
        let app = item.app
        AppActivator.queue.async {
            if let element, item.isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let fronted = PrivateAPI.focusWindow(pid: pid, windowID: wid)
            if let element {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            if !fronted {
                DispatchQueue.main.async { app.activate(options: [.activateIgnoringOtherApps]) }
            }
        }
    }

    static func hideApp(_ item: WindowItem) { item.app.hide() }

    static func quitApp(_ item: WindowItem) { item.app.terminate() }

    static func closeWindow(_ item: WindowItem) {
        press(kAXCloseButtonAttribute, item)
    }

    static func minimizeWindow(_ item: WindowItem) {
        guard let element = item.element else { return }
        AppActivator.queue.async {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private static func press(_ attribute: String, _ item: WindowItem) {
        guard let element = item.element else { return }
        AppActivator.queue.async {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(ref as! AXUIElement, kAXPressAction as CFString)
        }
    }
}
