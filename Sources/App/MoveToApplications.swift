import AppKit
import Darwin

/// Offers to move SwitchMux into /Applications when it was opened straight
/// from the DMG, Downloads, or any other folder.
///
/// This matters more than tidiness: macOS ties the Accessibility grant to the
/// app's location and signature, an app run from a read-only DMG is
/// translocated to a random path (so the grant never sticks), and the
/// self-updater can't replace a copy inside a disk image.
/// Adapted from alt-tab-macos (src/util/MoveToApplicationsFolder.swift).
enum MoveToApplications {
    private static let suppressKey = "moveToApplicationsSuppressed"

    static var bundlePath: String { Bundle.main.bundlePath }

    /// True when the app already lives in an Applications folder (and isn't
    /// nested inside another bundle), or is a dev build run from the repo.
    static var isInstalled: Bool {
        let path = bundlePath
        if isNestedInAnotherApp(path) { return false }
        for dir in NSSearchPathForDirectoriesInDomains(.applicationDirectory, .allDomainsMask, true)
            where path.hasPrefix(dir + "/") { return true }
        return (path as NSString).pathComponents.contains("Applications")
    }

    /// Running from a mounted disk image or an App Translocation path.
    static var isOnDiskImageOrTranslocated: Bool {
        bundlePath.contains("/AppTranslocation/") || containingDiskImageDevice(originalPath) != nil
    }

    /// Where the bundle really lives. Gatekeeper runs quarantined apps from a
    /// randomized read-only "App Translocation" mount; this resolves that back
    /// to the original location (e.g. /Volumes/SwitchMux or ~/Downloads).
    static var originalPath: String {
        let path = bundlePath
        guard path.contains("/AppTranslocation/") else { return path }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        guard let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return path }
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let url = fn(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else { return path }
        return (url as URL).path
    }

    /// Fast, main-thread-safe guess at "running from a DMG / translocated";
    /// `isOnDiskImageOrTranslocated` (runs hdiutil) confirms it.
    static var looksLikeDiskImage: Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }

    /// Dev builds (./build.sh output, smoke runs) never prompt or move.
    static var isDevBuild: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SWITCHMUX_NO_HOTKEYS"] != nil || env["SWITCHMUX_NO_MOVE"] != nil { return true }
        return bundlePath.contains("/build/SwitchMux.app")
    }

    /// Call once at launch, before anything else is set up. Shows the alert
    /// when needed; on "move" this copies, relaunches the copy and exits.
    static func promptIfNeeded() {
        guard !isInstalled, !isDevBuild else { return }
        // A disk image / translocated copy can never work properly, so the
        // "don't ask again" choice only applies to copies elsewhere on disk.
        let mustMove = isOnDiskImageOrTranslocated
        if !mustMove && UserDefaults.standard.bool(forKey: suppressKey) { return }

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "将 SwitchMux 移到「应用程序」文件夹？"
        alert.informativeText = mustMove
            ? "SwitchMux 正从磁盘映像中运行。移到「应用程序」后，辅助功能授权才能保留，自动更新也才能正常工作。"
            : "放在「应用程序」文件夹中，辅助功能授权和自动更新才能稳定工作。"
        alert.addButton(withTitle: "移到「应用程序」")
        let cancel = alert.addButton(withTitle: mustMove ? "退出" : "暂不移动")
        cancel.keyEquivalent = "\u{1b}"
        if !mustMove { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "不再询问" }
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            if mustMove { exit(0) }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
            return
        }
        switch moveNow() {
        case .relaunching, .disabled:
            exit(0)
        case .failed(let message):
            failed(message)
        }
    }

    enum Outcome {
        /// Copied; the new copy opens once this process exits (caller quits).
        case relaunching
        /// Dev / smoke build: moving is disabled on purpose.
        case disabled
        case failed(String)
    }

    /// Copies the bundle to /Applications, trashes a stray original (never a
    /// disk image / translocated / nested copy) and schedules the relaunch
    /// (plus ejecting the disk image). No UI: callers present errors. On
    /// `.relaunching` the caller must quit (NSApp.terminate or exit).
    static func moveNow() -> Outcome {
        guard !isDevBuild else { return .disabled }
        let fm = FileManager.default
        let source = bundlePath            // what we copy (translocated view is fine)
        let original = originalPath        // where it really lives
        let dmgDevice = containingDiskImageDevice(original)
        let destination = "/Applications/" + (original as NSString).lastPathComponent
        let destURL = URL(fileURLWithPath: destination)

        if !fm.isWritableFile(atPath: "/Applications")
            || (fm.fileExists(atPath: destination) && !fm.isWritableFile(atPath: destination)) {
            return .failed("没有写入「应用程序」文件夹的权限。请在访达中把 SwitchMux 拖到「应用程序」文件夹，再从那里打开。")
        }
        if fm.fileExists(atPath: destination) {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL.path == destURL.standardizedFileURL.path
            }) {
                // Same or older than the installed, running copy: just switch to it.
                guard isNewer(source, than: destination) else {
                    NSWorkspace.shared.open(destURL)
                    return .relaunching
                }
                // A newer build (manual update from a fresh DMG): quit the old one.
                running.terminate()
                let deadline = Date().addingTimeInterval(5)
                while !running.isTerminated && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                if !running.isTerminated {
                    return .failed("正在运行的旧版 SwitchMux 没有退出。请先从菜单栏退出它，再重新打开新版。")
                }
            }
            do {
                try fm.trashItem(at: destURL, resultingItemURL: nil)
            } catch {
                return .failed("无法替换「应用程序」中已有的 SwitchMux：\(error.localizedDescription)")
            }
        }
        do {
            // A translocated bundle is a read-only view of the original
            // (same signed contents), so copying it is fine.
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            return .failed("复制失败：\(error.localizedDescription)")
        }
        // Remove the stray original (Downloads etc.) — never a disk image,
        // never something nested in another bundle.
        if dmgDevice == nil && !original.contains("/AppTranslocation/") && !isNestedInAnotherApp(original)
            && original != destination {
            try? fm.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: nil)
        }
        relaunch(at: destination, dmgDevice: dmgDevice)
        return .relaunching
    }

    /// Waits for this process to exit, clears quarantine on the copy, opens
    /// it, then ejects the disk image we were launched from.
    private static func relaunch(at destination: String, dmgDevice: String?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = shellQuoted(destination)
        var script = "(while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; "
            + "/usr/bin/xattr -d -r com.apple.quarantine \(app) 2>/dev/null; /usr/bin/open \(app)"
        if let dmgDevice {
            script += "; /bin/sleep 3; /usr/bin/hdiutil detach \(shellQuoted(dmgDevice)) -quiet >/dev/null 2>&1"
        }
        script += ") &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }

    private static func failed(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法移到「应用程序」文件夹"
        alert.informativeText = message
        alert.runModal()
        if isOnDiskImageOrTranslocated { exit(0) }
    }

    // MARK: Helpers
    /// Compares CFBundleVersion (build number) of two app bundles.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        func build(_ path: String) -> Int {
            let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            return Int(plist?["CFBundleVersion"] as? String ?? "") ?? 0
        }
        return build(a) > build(b)
    }

    private static func isNestedInAnotherApp(_ path: String) -> Bool {
        ((path as NSString).deletingLastPathComponent as NSString).pathComponents
            .contains { ($0 as NSString).pathExtension == "app" }
    }

    /// Device of the mounted disk image containing `path`, if any.
    private static func containingDiskImageDevice(_ path: String) -> String? {
        var fs = statfs()
        guard statfs((path as NSString).deletingLastPathComponent, &fs) == 0,
              (Int32(fs.f_flags) & MNT_ROOTFS) == 0 else { return nil }
        let device = withUnsafeBytes(of: &fs.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return nil }
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? []
                where entity["dev-entry"] as? String == device {
                return device
            }
        }
        return nil
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
