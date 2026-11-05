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

    /// One-click guidance: open the Accessibility pane and dock the floating
    /// guide (with a draggable app icon) to it. The guide dismisses itself as
    /// soon as the grant is detected — no restart needed.
    static func guideToAccessibility() {
        PermissionWatcher.shared.refresh()
        openAccessibilitySettings()
        if !PermissionWatcher.shared.trusted {
            PermissionGuideController.shared.show(.accessibility)
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

    /// Prime the TCC entry, open the Screen Recording pane and dock the guide.
    static func guideToScreenRecording() {
        ScreenCapturePermission.request()
        openScreenRecordingSettings()
        PermissionGuideController.shared.show(.screenRecording)
    }

    static var accessibilityTrusted: Bool {
        if ProcessInfo.processInfo.environment["SWITCHMUX_SMOKE_UNTRUSTED"] != nil { return false }
        return AXIsProcessTrusted()
    }
}

/// Records one key press for an app's trigger while the preferences window is key.
/// Esc cancels, Delete clears the binding.
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()
    @Published var recordingAppID: UUID?
    @Published var message: String?

    private var monitor: Any?

    func toggle(_ appID: UUID) {
        if recordingAppID == appID { cancel() } else { start(appID) }
    }

    func start(_ appID: UUID) {
        cancel()
        recordingAppID = appID
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.handle(event)
            return nil
        }
    }

    func cancel() {
        recordingAppID = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let settings = SettingsStore.shared
        guard let appID = recordingAppID, settings.apps.contains(where: { $0.id == appID }) else {
            cancel()
            return
        }
        switch event.keyCode {
        case KeyCodes.escape:
            cancel()
            return
        case KeyCodes.delete, KeyCodes.forwardDelete:
            settings.bind(appID: appID, keyCode: nil, character: nil)
            cancel()
            return
        case KeyCodes.tab, KeyCodes.returnKey, KeyCodes.enter, KeyCodes.space,
             KeyCodes.left, KeyCodes.right, KeyCodes.up, KeyCodes.down:
            message = "这个键不能用作快捷键，请换一个字母、数字或符号键。"
            return
        default:
            break
        }
        // With the same modifier, ⌥` (key above Tab) belongs to window switching.
        if event.keyCode == KeyCodes.keyAboveTab, settings.appWindowSwitcherEnabled,
           settings.appWindowSwitcherModifier.flags == settings.activateModifiers {
            message = "\(settings.appWindowSwitcherModifier.symbol)` 已用于在同一应用的窗口间切换，请换一个键。"
            return
        }
        let raw = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let printable = raw.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && !raw.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) } // function keys
        guard let ch = (printable && !raw.isEmpty ? raw : nil) ?? KeyCodes.character(for: event.keyCode) else {
            message = "这个键不能用作快捷键，请换一个字母、数字或符号键。"
            return
        }
        if let displaced = settings.bind(appID: appID, keyCode: event.keyCode, character: ch) {
            message = "「\(ch.uppercased())」原先属于「\(displaced)」，已改为分配给当前应用。"
        } else {
            message = nil
        }
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
    var wide = false
    var dimmed = false
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(dimmed ? Color.secondary : Color.white)
            .frame(minWidth: wide ? 26 : 22, minHeight: 20)
            .padding(.horizontal, 4)
            .background(dimmed ? Color.secondary.opacity(0.15) : Color.black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Row of key-cap toggles for picking one or more modifier keys.
struct ModifierPicker: View {
    @Binding var flags: NSEvent.ModifierFlags

    private let options: [(String, String, NSEvent.ModifierFlags)] = [
        ("⌃", "Control", .control), ("⌥", "Option", .option),
        ("⇧", "Shift", .shift), ("⌘", "Command", .command),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.1) { symbol, name, flag in
                let on = flags.contains(flag)
                Button {
                    var next = flags
                    if on { next.remove(flag) } else { next.insert(flag) }
                    // Never allow an empty mask, and never Shift alone.
                    let relevant = next.intersection(KeyChord.relevant)
                    if !relevant.isEmpty && relevant != .shift { flags = relevant }
                } label: {
                    HStack(spacing: 4) {
                        Text(symbol).font(.system(size: 13, weight: .semibold))
                        Text(name).font(.system(size: 11))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
