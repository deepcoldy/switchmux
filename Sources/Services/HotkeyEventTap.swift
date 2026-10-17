import AppKit
import CoreGraphics

/// Session-wide event tap for modifier holds (flagsChanged) and key presses.
/// Uses a default (non-listen-only) tap so trigger keys can be swallowed.
/// Creation fails (returns nil) until Accessibility is granted; call
/// `ensureStarted()` again after the grant flips — no app restart needed.
final class HotkeyEventTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// Called on the main thread. Return true to swallow the event.
    var onKeyDown: ((NSEvent) -> Bool)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?

    func start() {
        stop()
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let owner = Unmanaged<HotkeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.dispatch(type: type, cgEvent: cgEvent)
            },
            userInfo: refcon
        ) else {
            isActive = false
            NSLog("SwitchMux: event tap unavailable (waiting for Accessibility permission)")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    private func dispatch(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let event = NSEvent(cgEvent: cgEvent) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        if ProcessInfo.processInfo.environment["SWITCHMUX_TRACE"] != nil {
            NSLog("TRACE raw type=\(type.rawValue) ch=\(event.charactersIgnoringModifiers ?? "-")")
        }
        switch type {
        case .flagsChanged:
            if ProcessInfo.processInfo.environment["SWITCHMUX_TRACE"] != nil {
                NSLog("TRACE flagsChanged \(event.modifierFlags.rawValue)")
            }
            onFlagsChanged?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        case .keyDown:
            if ProcessInfo.processInfo.environment["SWITCHMUX_TRACE"] != nil {
                NSLog("TRACE keyDown \(event.charactersIgnoringModifiers ?? "?") flags=\(event.modifierFlags.rawValue)")
            }
            if onKeyDown?(event) == true {
                return nil // swallow
            }
        default:
            break
        }
        return Unmanaged.passUnretained(cgEvent)
    }
}
