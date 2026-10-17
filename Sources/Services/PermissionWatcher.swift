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

    /// Debug hook: synthesize a grant transition without touching TCC.
    func debugSimulateChange(_ value: Bool) {
        trusted = value
        changePublisher.send(value)
    }
}
