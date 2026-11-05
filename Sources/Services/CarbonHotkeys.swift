import AppKit
import Carbon.HIToolbox

/// Global hotkeys registered through Carbon's `RegisterEventHotKey`.
///
/// Unlike an event tap these keep working while Secure Keyboard Entry is on
/// (password fields, Terminal's secure input, 1Password…), never time out when
/// the main thread is busy, and are consumed before the frontmost app sees
/// them. Used for the switcher triggers (⌘Tab, ⌥` …), as alt-tab does.
final class CarbonHotkeys {
    static let shared = CarbonHotkeys()

    private static let signature: OSType = 0x534D_5558 // "SMUX"

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == CarbonHotkeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            CarbonHotkeys.shared.fire(hotKeyID.id)
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }

    /// Registers keyCode + modifiers. Returns false if another app already owns
    /// the combination (the caller then falls back to the event tap).
    @discardableResult
    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SwitchMux: RegisterEventHotKey failed (key \(keyCode), mods \(modifiers.rawValue)): \(status)")
            return false
        }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
