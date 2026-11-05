import AppKit
import CoreGraphics

/// A key + exact modifier set (only ⌘ ⇧ ⌥ ⌃ are considered).
struct KeyChord: Hashable {
    let keyCode: UInt16
    let modifiers: UInt

    init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(KeyChord.relevant).rawValue
    }

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
}

/// Session-wide keyboard event tap running on its OWN thread.
///
/// The old tap lived on the main run loop: any main-thread stall (AX calls to
/// a hung app, a slow iCloud write, layout) delayed every keystroke system-wide
/// and made macOS disable the tap with `tapDisabledByTimeout`, which is what
/// made the hotkeys "randomly stop working". Now the callback only reads a
/// lock-protected routing table, decides synchronously whether to swallow,
/// and hands the actual work to the main thread asynchronously.
final class HotkeyEventTap {
    /// What the tap should swallow. Written from the main thread.
    struct Routing {
        /// App Bar: exact modifier mask that must be held + bound key codes.
        var barMask: NSEvent.ModifierFlags = .option
        var barKeyCodes: Set<UInt16> = []
        var barKeysEnabled = true
        /// A switcher session is open: swallow (almost) every key and route it there.
        var sessionActive = false
        /// Chords owned by Carbon hotkeys: always pass through untouched.
        var carbonChords: Set<KeyChord> = []
        /// Trigger chords Carbon could not register: the tap handles them itself.
        var fallbackTriggers: [KeyChord: Int] = [:]
    }

    /// Main-thread callbacks.
    /// Flags + the moment the event reached the tap (not when main got to it).
    var onFlagsChanged: ((NSEvent.ModifierFlags, CFAbsoluteTime) -> Void)?
    var onBarKey: ((UInt16) -> Void)?
    var onSessionKey: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onFallbackTrigger: ((Int) -> Void)?

    private let lock = NSLock()
    private var routing = Routing()
    private var lastKeyDownTime: CFAbsoluteTime = 0

    // Tap-thread-only state.
    private var swallowedKeyDowns = Set<UInt16>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let thread = RunLoopThread(name: "SwitchMux.EventTap")

    private(set) var isActive = false

    // MARK: Routing (thread-safe)
    func updateRouting(_ mutate: (inout Routing) -> Void) {
        lock.lock()
        mutate(&routing)
        lock.unlock()
    }

    private func currentRouting() -> Routing {
        lock.lock()
        defer { lock.unlock() }
        return routing
    }

    /// Time of the most recent physical key-down (any key).
    var lastKeyDown: CFAbsoluteTime {
        lock.lock()
        defer { lock.unlock() }
        return lastKeyDownTime
    }

    // MARK: Lifecycle
    func start() {
        stop()
        thread.startIfNeeded()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<HotkeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            isActive = false
            NSLog("SwitchMux: event tap unavailable (waiting for Accessibility permission)")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(thread.runLoop, source, .commonModes)
        CFRunLoopWakeUp(thread.runLoop)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource, let rl = thread.runLoopIfStarted {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    // MARK: Callback (tap thread)
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
            let time = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async { [weak self] in self?.onFlagsChanged?(flags, time) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let chord = KeyChord(keyCode, flags)

            lock.lock()
            lastKeyDownTime = CFAbsoluteTimeGetCurrent()
            let r = routing
            lock.unlock()

            if let trigger = r.fallbackTriggers[chord] {
                if !r.sessionActive {
                    // Mark the session open right here so the very next key
                    // (arriving before main catches up) is routed too.
                    updateRouting { $0.sessionActive = true }
                }
                DispatchQueue.main.async { [weak self] in self?.onFallbackTrigger?(trigger) }
                swallowedKeyDowns.insert(keyCode)
                return nil
            }
            // Carbon owns it: let it through so the hotkey fires exactly once.
            if r.carbonChords.contains(chord) { return Unmanaged.passUnretained(event) }

            if r.sessionActive {
                DispatchQueue.main.async { [weak self] in self?.onSessionKey?(keyCode, flags) }
                swallowedKeyDowns.insert(keyCode)
                return nil
            }

            if r.barKeysEnabled,
               flags.intersection(KeyChord.relevant) == r.barMask,
               r.barKeyCodes.contains(keyCode) {
                if !isRepeat {
                    DispatchQueue.main.async { [weak self] in self?.onBarKey?(keyCode) }
                }
                swallowedKeyDowns.insert(keyCode)
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Never leak the key-up of a key-down we swallowed.
            if swallowedKeyDowns.remove(keyCode) != nil { return nil }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// A dedicated thread with a live CFRunLoop for the event tap source.
private final class RunLoopThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var started = false
    private var loop: CFRunLoop?

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    var runLoop: CFRunLoop { loop! }
    var runLoopIfStarted: CFRunLoop? { loop }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        start()
        ready.wait()
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A far-future timer keeps the run loop alive while no tap is attached.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                        CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        ready.signal()
        while !isCancelled {
            CFRunLoopRunInMode(.defaultMode, 1e9, false)
        }
    }
}
