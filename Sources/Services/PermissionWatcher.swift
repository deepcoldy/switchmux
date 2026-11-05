import AppKit
import ApplicationServices
import Combine

/// Polls the Accessibility TCC grant. macOS does not notify on change, but
/// `AXIsProcessTrusted()` reflects grants/revocations live for the running
/// process — this lets us (re)build the event tap the moment access is granted,
/// so the hotkey works without relaunching the app.
final class PermissionWatcher: ObservableObject {
    static let shared = PermissionWatcher()

    @Published private(set) var trusted: Bool = AXIsProcessTrusted()
    /// Fires on the main thread whenever the grant state flips.
    let changePublisher = PassthroughSubject<Bool, Never>()

    private var timer: Timer?

    private init() {}

    func start() {
        trusted = AXIsProcessTrusted()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @discardableResult
    func refresh() -> Bool {
        let now = AXIsProcessTrusted()
        if now != trusted {
            trusted = now
            changePublisher.send(now)
        }
        return now
    }

    /// System TCC prompt ("would like to control this app…"), first run only.
    func systemPrompt() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    /// Removes SwitchMux's Accessibility record (only our own bundle ID) and
    /// re-registers it. Fixes the common case where the list shows SwitchMux
    /// switched on but the grant belongs to an older build with a different
    /// signature, so it silently doesn't apply.
    func resetAndReRegister() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", bid]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.systemPrompt()
                PrefsSupport.openAccessibilitySettings()
            }
        }
        do { try p.run() } catch { NSLog("SwitchMux: tccutil failed: \(error)") }
    }

    /// Debug hook: synthesize a grant transition without touching TCC.
    func debugSimulateChange(_ value: Bool) {
        trusted = value
        changePublisher.send(value)
    }
}
