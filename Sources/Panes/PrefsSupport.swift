import AppKit
import SwiftUI

/// AppKit bridges used by the SwiftUI preference panes.
enum PrefsSupport {
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    static func chooseApplications() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        let response = panel.runModal()
        return response == .OK ? panel.urls : []
    }

    static func makeAction(url: URL, character: String? = nil) -> ProfileAction {
        let name = url.deletingPathExtension().lastPathComponent
        let bid = Bundle(url: url)?.bundleIdentifier
        return ProfileAction(name: name, path: url.path, bundleID: bid, character: character)
    }

    struct RunningApp {
        let name: String
        let bundleID: String?
        let url: URL
    }

    static func runningApplications() -> [RunningApp] {
        AppsMonitor.shared.regularApps.compactMap { app in
            guard let url = app.bundleURL else { return nil }
            return RunningApp(
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier, url: url)
        }
    }

    static func openAccessibilitySettings() {
        let workspace = NSWorkspace.shared
        // Ventura+ URL scheme; fall back to the legacy pane id.
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for raw in urls {
            if let url = URL(string: raw), workspace.urlForApplication(toOpen: url) != nil {
                if workspace.open(url) { return }
            }
        }
    }

    /// Reveal SwitchMux.app selected in a Finder window so it can be dragged
    /// into the TCC list.
    @discardableResult
    static func revealAppInFinder() -> Bool {
        guard let url = Bundle.main.bundleURL.path.hasSuffix(".app")
                ? Bundle.main.bundleURL
                : Bundle.main.resourceURL?.deletingLastPathComponent().deletingLastPathComponent() else {
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// One-click guidance: open the Accessibility pane, reveal the app in
    /// Finder and present the floating drag guide. It dismisses as soon as the
    /// grant is detected — no restart needed.
    static func guideToAccessibility() {
        PermissionWatcher.shared.refresh()
        if !PermissionWatcher.shared.trusted {
            PermissionGuideController.shared.show()
        }
        revealAppInFinder()
        // Give Finder a moment, then bring System Settings forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            openAccessibilitySettings()
        }
    }

    // MARK: Screen Recording
    static func openScreenRecordingSettings() {
        let workspace = NSWorkspace.shared
        for raw in [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ] {
            if let url = URL(string: raw), workspace.urlForApplication(toOpen: url) != nil {
                if workspace.open(url) { return }
            }
        }
    }

    /// Prime the TCC entry, reveal the app in Finder and open the Screen
    /// Recording pane.
    static func guideToScreenRecording() {
        ScreenCapturePermission.request()
        revealAppInFinder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            openScreenRecordingSettings()
        }
    }

    static var accessibilityTrusted: Bool {
        if ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_UNTRUSTED"] != nil { return false }
        return AXIsProcessTrusted()
    }
}

/// Records one key press while the preferences window is key.
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()
    @Published var recordingActionID: UUID?
    @Published var conflictMessage: String?

    private var monitor: Any?
    private var profileID: UUID?

    func startRecording(for actionID: UUID, profileID: UUID) {
        recordingActionID = actionID
        self.profileID = profileID
        conflictMessage = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.assign(event)
            return nil
        }
    }

    func cancel() {
        recordingActionID = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func assign(_ event: NSEvent) {
        guard let actionID = recordingActionID, let profileID else { cancel(); return }
        let settings = SettingsStore.shared
        guard let profile = settings.profile(profileID),
              var copy = Optional(profile),
              let idx = copy.actions.firstIndex(where: { $0.id == actionID }) else {
            cancel()
            return
        }
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if !ch.isEmpty, let conflict = copy.actions.first(where: { $0.character == ch && $0.id != actionID }) {
            conflictMessage = "「\(ch.uppercased())」已被「\(conflict.name)」使用，请先移除或修改另一个快捷键。"
            cancel()
            return
        }
        copy.actions[idx].character = ch.isEmpty ? nil : ch
        settings.update(copy)
        cancel()
    }
}

extension View {
    @ViewBuilder
    func prefsSection<Header: View>(@ViewBuilder header: () -> Header) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header()
                .font(.headline)
            self
        }
    }
}

/// Small rounded key-cap badge like the one on the App Bar.
struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 22, minHeight: 19)
            .padding(.horizontal, 3)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }
}
