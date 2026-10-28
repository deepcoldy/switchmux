import AppKit

// Single-instance guard. Launching the bundled binary directly (bypassing
// Launch Services, which already dedupes `open`) would create a second status
// item and a competing event tap. Only treat another LIVE copy of the SAME
// app bundle as a duplicate — stale exiting processes left over from replaced
// builds live at a different path and must not block a fresh launch.
if let ownID = Bundle.main.bundleIdentifier {
    let ownURL = Bundle.main.bundleURL.standardizedFileURL
    let duplicate = NSWorkspace.shared.runningApplications.contains { app in
        guard app.bundleIdentifier == ownID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          !app.isTerminated,
          let otherURL = app.bundleURL?.standardizedFileURL else { return false }
        return otherURL == ownURL
    }
    if duplicate { exit(0) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
