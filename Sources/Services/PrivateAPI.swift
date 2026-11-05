import AppKit
import ApplicationServices

/// Private SkyLight / HIServices entry points, resolved at runtime with dlsym
/// so the build needs no private-framework linking. Every symbol is optional:
/// if one disappears in a future macOS, callers fall back to public APIs.
///
/// Approach follows alt-tab-macos (src/macos/api-wrappers/SkyLight.framework.swift).
enum PrivateAPI {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func symbol<T>(_ name: String, in handles: [UnsafeMutableRawPointer?], as _: T.Type) -> T? {
        for handle in handles + [defaultHandle] {
            if let ptr = dlsym(handle, name) { return unsafeBitCast(ptr, to: T.self) }
        }
        return nil
    }

    // MARK: Symbols
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> CGError
    typealias IsSymbolicHotKeyEnabledFn = @convention(c) (Int32) -> Bool
    typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: [skyLight], as: SetFrontProcessFn.self)
    static let postEventRecord = symbol("SLPSPostEventRecordTo", in: [skyLight], as: PostEventRecordFn.self)
    static let getProcessForPID = symbol("GetProcessForPID", in: [appServices], as: GetProcessForPIDFn.self)
    static let setSymbolicHotKeyEnabled = symbol("CGSSetSymbolicHotKeyEnabled", in: [skyLight], as: SetSymbolicHotKeyEnabledFn.self)
    static let isSymbolicHotKeyEnabled = symbol("CGSIsSymbolicHotKeyEnabled", in: [skyLight], as: IsSymbolicHotKeyEnabledFn.self)
    static let axGetWindow = symbol("_AXUIElementGetWindow", in: [appServices], as: AXGetWindowFn.self)

    // MARK: Helpers
    /// CGWindowID of an AX window element (0 when unavailable).
    static func windowID(of element: AXUIElement) -> CGWindowID {
        guard let axGetWindow else { return 0 }
        var id = CGWindowID(0)
        return axGetWindow(element, &id) == .success ? id : 0
    }

    /// Fronts `pid` and makes `windowID` its key window. Public APIs can't do
    /// this reliably from a background (accessory) app: since macOS 14
    /// `NSRunningApplication.activate` is only an advisory request.
    /// Returns false when the private symbols are missing.
    @discardableResult
    static func focusWindow(pid: pid_t, windowID: CGWindowID, allWindows: Bool = false) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // 0x200 = user generated; 0x100 = also bring the app's other windows.
        let mode: UInt32 = allWindows ? 0x300 : 0x200
        _ = setFrontProcess(&psn, windowID, mode)
        if windowID != 0 { makeKeyWindow(&psn, windowID) }
        return true
    }

    /// Synthetic left-mouse-down record aimed far off the window so it becomes
    /// key without any of its content being clicked (alt-tab's layout).
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let postEventRecord else { return }
        var wid = windowID
        var point = CGPoint(x: 300_000, y: 300_000)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8   // record length
        bytes[0x3a] = 0x10   // undocumented flag (yabai / Hammerspoon)
        bytes[0x08] = 0x01   // kCGEventLeftMouseDown
        withUnsafeBytes(of: &wid) { src in
            for i in 0..<src.count { bytes[0x3c + i] = src[i] }
        }
        withUnsafeBytes(of: &point) { src in
            for i in 0..<src.count { bytes[0x20 + i] = src[i] }
        }
        bytes.withUnsafeMutableBufferPointer { buf in
            _ = postEventRecord(&psn, buf.baseAddress!)
        }
    }
}

/// Native ⌘Tab / ⌘⇧Tab are matched by the WindowServer's symbolic-hotkey
/// layer ahead of every app, so SwitchMux can only own ⌘Tab reliably by
/// switching them off. That state lives in the WindowServer and outlasts our
/// process, so it is restored on quit, on fatal signals, by a watchdog process
/// if we're killed outright (SIGKILL / Force Quit), and whenever the takeover
/// is turned off.
enum NativeCommandTab {
    private static let hotkeyIDs: [Int32] = [1, 2] // commandTab, commandShiftTab
    /// What SwitchMux wants: true = native ⌘Tab must be off.
    private(set) static var wantDisabled = false
    private static var watchdog: Process?

    static let watchdogFlag = "--restore-cmdtab-after"

    /// Live WindowServer state (nil if the query symbol is unavailable).
    private static var nativeEnabledNow: Bool? {
        guard let fn = PrivateAPI.isSymbolicHotKeyEnabled else { return nil }
        return hotkeyIDs.allSatisfy { fn($0) }
    }

    private static func write(_ enabled: Bool) {
        guard let fn = PrivateAPI.setSymbolicHotKeyEnabled else { return }
        for id in hotkeyIDs { _ = fn(id, enabled) }
    }

    static func setNativeEnabled(_ enabled: Bool) {
        wantDisabled = !enabled
        reassert()
        if wantDisabled { startWatchdog() } else { stopWatchdog() }
    }

    /// Re-applies the wanted state against the live one, e.g. after another
    /// process turned native ⌘Tab back on behind our back.
    static func reassert() {
        if wantDisabled {
            if nativeEnabledNow != false { write(false) }
        } else if nativeEnabledNow == false {
            write(true)
        }
    }

    /// At launch: a crashed earlier instance may have left it off.
    static func forceRestore() {
        write(true)
    }

    static func restoreIfNeeded() {
        guard wantDisabled else { return }
        wantDisabled = false
        write(true)
    }

    /// Clean shutdown: restore ourselves and retire the watchdog first, so it
    /// can't later re-enable native ⌘Tab underneath a relaunched instance.
    static func shutdown() {
        stopWatchdog()
        restoreIfNeeded()
    }

    static func installCrashGuards() {
        atexit { NativeCommandTab.restoreIfNeeded() }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                NativeCommandTab.restoreIfNeeded()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    // MARK: Watchdog
    private static func startWatchdog() {
        guard watchdog?.isRunning != true, let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = [watchdogFlag, String(ProcessInfo.processInfo.processIdentifier)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); watchdog = p } catch { NSLog("SwitchMux: watchdog failed to start: \(error)") }
    }

    private static func stopWatchdog() {
        if let p = watchdog, p.isRunning { p.terminate() }
        watchdog = nil
    }

    /// Entry point of the watchdog process (see main.swift): block until
    /// `pid` exits, then re-enable native ⌘Tab. Never returns.
    static func runWatchdog(parent pid: pid_t) -> Never {
        // Exit quietly if asked to stop (clean shutdown of the parent).
        signal(SIGTERM) { _ in exit(0) }
        let kq = kqueue()
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        var event = kevent()
        if kq >= 0, kevent(kq, &change, 1, nil, 0, nil) == 0 {
            _ = kevent(kq, nil, 0, &event, 1, nil)
        } else {
            // Fallback: poll for the parent.
            while kill(pid, 0) == 0 { usleep(500_000) }
        }
        write(true)
        exit(0)
    }
}
