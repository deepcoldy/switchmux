import AppKit
import ApplicationServices

/// Launches / activates / hides applications — the core switching actions.
enum AppActivator {
    enum Result {
        case launched
        case activated
        case hidden
    }

    @discardableResult
    static func trigger(_ slot: Slot, allowHide: Bool) -> Result {
        // Already running?
        if let app = AppsMonitor.shared.runningApp(forURL: slot.url)
            ?? AppsMonitor.shared.runningApp(forBundleID: slot.bundleID) {
            if app.isActive {
                if allowHide {
                    setHidden(true, pid: app.processIdentifier)
                    return .hidden
                }
                return .activated
            }
            if app.isHidden {
                setHidden(false, pid: app.processIdentifier)
            }
            app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            return .activated
        }
        // Not running: launch it.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: slot.url, configuration: config)
        return .launched
    }

    /// Show / hide an app via Accessibility (same privilege the event tap needs).
    static func setHidden(_ hidden: Bool, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXHidden" as CFString, hidden ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
