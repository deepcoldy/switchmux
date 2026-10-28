import Foundation

enum UpdateInstaller {
    enum AttachResult {
        case mounted(app: URL, mountPoint: URL, workDir: URL)
        case failure(String)
    }

    /// Mounts the DMG at a fixed mountpoint under a fresh work directory and
    /// locates the single .app on the volume.
    static func attach(_ dmg: URL, completion: @escaping (AttachResult) -> Void) {
        let workDir: URL
        do {
            workDir = try UpdateStore.shared.newWorkDirectory()
        } catch {
            completion(.failure("无法创建临时工作目录"))
            return
        }
        let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["attach", dmg.path,
                           "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                           "-mountpoint", mountPoint.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let workItem = DispatchWorkItem { if p.isRunning { p.terminate() } }
            do {
                try p.run()
            } catch {
                completion(.failure("无法启动 hdiutil"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: workItem)
            p.waitUntilExit()
            workItem.cancel()

            guard p.terminationStatus == 0 else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("SwitchMuxUpdater: hdiutil attach failed: \(output)")
                try? FileManager.default.removeItem(at: workDir)
                completion(.failure(UpdateError.attachFailed.userMessage))
                return
            }

            // Locate exactly one app at the volume root; prefer SwitchMux.app.
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: mountPoint,
                                                            includingPropertiesForKeys: [.isDirectoryKey]) else {
                completion(.failure(UpdateError.attachFailed.userMessage))
                return
            }
            let apps = entries.filter { $0.pathExtension == "app" }
            let preferred = apps.first { $0.lastPathComponent == "SwitchMux.app" }
            guard let app = preferred ?? apps.first, apps.count == 1 || preferred != nil else {
                detach(mountPoint)
                try? FileManager.default.removeItem(at: workDir)
                completion(.failure("映像中未找到唯一的 SwitchMux.app"))
                return
            }
            completion(.mounted(app: app, mountPoint: mountPoint, workDir: workDir))
        }
    }

    static func detach(_ mountPoint: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", mountPoint.path, "-force"]
        try? p.run()
    }

    static func canReplaceRunningApp() -> Bool { AppInfo.canReplaceInPlace() }

    /// Verifies the mounted app, writes a detached installer script, spawns it
    /// under nohup, and reports success — the caller then terminates.
    /// completion: (success, userMessage)
    static func commitAndRelaunch(app: URL,
                                  mountPoint: URL,
                                  workDir: URL,
                                  pending: PendingUpdate,
                                  completion: @escaping (Bool, String) -> Void) {
        let target = SemVer(string: pending.version) ?? .zero
        let allowAdhoc = ProcessInfo.processInfo.environment["SWITCHMUX_UPDATE_ALLOW_ADHOC"] != nil
        let report = UpdateVerifier.verifyMountedApp(app, target: target, allowAdhoc: allowAdhoc)
        guard report.passed else {
            detach(mountPoint)
            try? FileManager.default.removeItem(at: workDir)
            completion(false, report.message)
            return
        }
        guard canReplaceRunningApp() else {
            detach(mountPoint)
            try? FileManager.default.removeItem(at: workDir)
            completion(false, UpdateError.readOnlyLocation.userMessage)
            return
        }

        let oldApp = Bundle.main.bundleURL
        let script = workDir.appendingPathComponent("install.sh")
        let log = workDir.appendingPathComponent("install.log")
        let dmg = pending.dmgURL

        do {
            try installerScript.data(using: .utf8)?.write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            completion(false, "无法写入安装脚本")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", script.path,
                       String(ProcessInfo.processInfo.processIdentifier),
                       app.path, oldApp.path, mountPoint.path, dmg.path, log.path]
        // Detach from this process's std streams.
        if let devnull = FileHandle(forWritingAtPath: "/dev/null") {
            p.standardInput = devnull
            p.standardOutput = devnull
            p.standardError = devnull
        }
        do {
            try p.run()
        } catch {
            completion(false, "无法启动安装进程")
            return
        }
        completion(true, "")
    }

    /// Waits for the parent to exit, swaps the bundle via ditto+mv, detaches
    /// the image, relaunches through Launch Services, and cleans up.
    private static let installerScript = #"""
#!/bin/bash
# Generated by SwitchMux updater.
trap '' HUP
PARENT_PID="$1"; NEW_APP="$2"; OLD_APP="$3"; MOUNT="$4"; DMG="$5"; LOG="$6"
exec >>"$LOG" 2>&1
set -x

for _ in $(seq 1 200); do kill -0 "$PARENT_PID" 2>/dev/null || break; sleep 0.1; done
sleep 0.6

if ! /usr/bin/ditto "$NEW_APP" "$OLD_APP.tmp"; then
    /bin/rm -rf "$OLD_APP.tmp"; exit 10
fi
/bin/rm -rf "$OLD_APP"
if ! /bin/mv "$OLD_APP.tmp" "$OLD_APP"; then
    /usr/bin/ditto "$NEW_APP" "$OLD_APP" || { /bin/rm -rf "$OLD_APP"; exit 11; }
fi

/usr/bin/hdiutil detach "$MOUNT" -force || true
/bin/sleep 0.3
/usr/bin/open "$OLD_APP"

/bin/rm -f "$DMG"
/bin/rm -rf "$(dirname "$MOUNT")"
"""#
}
