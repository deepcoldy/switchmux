import AppKit
import Combine
import SwiftUI

/// First-run onboarding: install location → Accessibility (required) →
/// Screen Recording (optional) → shortcut cheat-sheet.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    static let size = NSSize(width: 560, height: 510)
    let model = WelcomeModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeWindowController.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "欢迎使用 SwitchMux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self

        let host = NSHostingView(rootView: WelcomeView(model: model))
        // Fixed-size window: don't let SwiftUI's ideal size resize it per step.
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(WelcomeWindowController.size)
    }

    func showWindow() {
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil as Any?)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }

    /// Rasterizes the window content (whatever step is current).
    func smokeDump(to path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Model

enum WelcomeStep: Int, CaseIterable {
    case install, accessibility, screenRecording, finish

    var title: String {
        switch self {
        case .install: return "安装"
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .finish: return "完成"
        }
    }
}

enum ProbeState { case checking, granted, denied }

final class WelcomeModel: ObservableObject {
    @Published var step: WelcomeStep = .install
    @Published var installed = MoveToApplications.isInstalled
    /// Starts from a cheap path check; hdiutil confirms it off the main thread.
    @Published var onDiskImage = MoveToApplications.looksLikeDiskImage
    /// Inline feedback from the install button (failure, dev build).
    @Published var installMessage: String?
    @Published var trusted = PrefsSupport.accessibilityTrusted
    @Published var screenRecording: ProbeState = .checking

    private var started = false
    private var axTimer: Timer?
    private var probeTimer: Timer?
    private var probing = false
    private var cancellables = Set<AnyCancellable>()
    private let env = ProcessInfo.processInfo.environment

    private var forceUntrusted: Bool { env["SWITCHMUX_SMOKE_UNTRUSTED"] != nil }

    init() {
        $step.removeDuplicates()
            .sink { [weak self] step in
                // Defer so the @Published value is committed before we read it.
                DispatchQueue.main.async { self?.stepChanged(to: step) }
            }
            .store(in: &cancellables)
        PermissionWatcher.shared.changePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTrust() }
            .store(in: &cancellables)
    }

    func start() {
        installed = MoveToApplications.isInstalled
        trusted = PrefsSupport.accessibilityTrusted
        checkDiskImage()

        // Each (re)open starts at the first step that still needs doing.
        // Debug: SWITCHMUX_WELCOME_STEP=1…4 forces a step on the first open.
        let firstOpen = !started
        started = true
        if firstOpen, let raw = env["SWITCHMUX_WELCOME_STEP"], let n = Int(raw),
           let forced = WelcomeStep(rawValue: max(0, min(n - 1, WelcomeStep.allCases.count - 1))) {
            step = forced
        } else {
            if !installed {
                step = .install
            } else if !trusted {
                step = .accessibility
            } else {
                step = .screenRecording
            }
        }

        // Accessibility is cheap to read; PermissionWatcher also pushes
        // changes, this just covers the case where it isn't running.
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTrust()
        }
        stepChanged(to: step)
    }

    func stop() {
        axTimer?.invalidate(); axTimer = nil
        probeTimer?.invalidate(); probeTimer = nil
    }

    func next() {
        if let n = WelcomeStep(rawValue: step.rawValue + 1) { step = n }
    }

    func back() {
        if let p = WelcomeStep(rawValue: step.rawValue - 1) { step = p }
    }

    func isDone(_ s: WelcomeStep) -> Bool {
        switch s {
        case .install: return installed
        case .accessibility: return trusted
        case .screenRecording: return screenRecording == .granted
        case .finish: return false
        }
    }

    // MARK: Install

    /// The button is the user's decision, so move straight away: no second
    /// confirmation alert, and the launch alert's "不再询问" flag is untouched.
    func moveToApplications() {
        installMessage = nil
        switch MoveToApplications.moveNow() {
        case .relaunching:
            NSApp.terminate(nil)  // the /Applications copy opens once we exit
        case .disabled:
            installMessage = "这是开发版本，不会自动移动。"
        case .failed(let message):
            installMessage = message
        }
        installed = MoveToApplications.isInstalled
    }

    private func checkDiskImage() {
        guard !installed else { onDiskImage = false; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = MoveToApplications.isOnDiskImageOrTranslocated
            DispatchQueue.main.async { self.onDiskImage = value }
        }
    }

    /// Grants are completed in System Settings, which hides this window.
    /// Bring it back (and drop the docked guide) so the flow is visible.
    private func bringBack() {
        // Closed by the user: don't pop it back up.
        guard WelcomeWindowController.shared.window?.isVisible == true else { return }
        PermissionGuideController.shared.hide()
        NSApp.activate(ignoringOtherApps: true)
        WelcomeWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Accessibility

    private func refreshTrust() {
        let now = PrefsSupport.accessibilityTrusted
        guard now != trusted else { return }
        trusted = now
        if now && step == .accessibility {
            bringBack()
            // Let the check mark register, then move on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                if self?.step == .accessibility { self?.next() }
            }
        }
    }

    // MARK: Screen Recording

    private func stepChanged(to step: WelcomeStep) {
        probeTimer?.invalidate(); probeTimer = nil
        guard step == .screenRecording, started, axTimer != nil else { return }
        probe()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.probe()
        }
    }

    private func probe() {
        if forceUntrusted { screenRecording = .denied; return }
        guard !probing else { return }
        probing = true
        WindowCapture.probe { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                let wasDenied = self.screenRecording == .denied
                self.screenRecording = granted ? .granted : .denied
                if granted {
                    self.probeTimer?.invalidate(); self.probeTimer = nil
                    // Only when it flipped while the user was off granting it.
                    if wasDenied && self.step == .screenRecording { self.bringBack() }
                }
            }
        }
    }
}

// MARK: - Views

private struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
            StepIndicator(model: model)
                .padding(.top, 22)
                .padding(.horizontal, 48)

            Group {
                switch model.step {
                case .install: InstallStep(model: model)
                case .accessibility: AccessibilityStep(model: model)
                case .screenRecording: ScreenRecordingStep(model: model)
                case .finish: FinishStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 48)
            .padding(.top, 24)
        }
        .frame(width: WelcomeWindowController.size.width,
               height: WelcomeWindowController.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("欢迎使用 SwitchMux")
                .font(.system(size: 22, weight: .semibold))
            Text("用键盘快速打开和切换应用，只需几步即可完成设置。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StepIndicator: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(WelcomeStep.allCases, id: \.rawValue) { s in
                if s.rawValue > 0 {
                    Rectangle()
                        // Filled only when the step before it is really done,
                        // so a skipped step doesn't read as progress.
                        .fill(model.isDone(WelcomeStep(rawValue: s.rawValue - 1)!)
                              ? Color.accentColor.opacity(0.6)
                              : Color.secondary.opacity(0.25))
                        .frame(height: 2)
                        .padding(.top, 11)
                        .frame(maxWidth: .infinity)
                }
                VStack(spacing: 6) {
                    dot(for: s)
                    Text(s.title)
                        .font(.caption)
                        .foregroundStyle(s == model.step ? .primary : .secondary)
                        .fixedSize()
                }
                .frame(width: 24)
            }
        }
    }

    @ViewBuilder
    private func dot(for s: WelcomeStep) -> some View {
        let current = s == model.step
        let done = model.isDone(s)
        ZStack {
            Circle()
                .fill(current ? Color.accentColor
                      : done ? Color.accentColor.opacity(0.28)
                      : Color.secondary.opacity(0.12))
            Circle()
                .strokeBorder(current || done ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1)
            if done && !current {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
            } else {
                Text("\(s.rawValue + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current ? Color.white : Color.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// Shared layout for one step: icon + heading + body, then a footer bar with
/// a link-style back button on the left and the single primary button on the right.
private struct StepPage<Content: View, Footer: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var badge: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

            Spacer(minLength: 12)
            HStack(spacing: 16) { footer() }
                .frame(height: 32)
                .padding(.bottom, 26)
        }
    }
}

private struct BodyText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLine: View {
    enum Kind { case ok, waiting, warning }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .waiting:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(text).font(.callout)
                .foregroundStyle(kind == .ok ? Color.primary : Color.secondary)
        }
    }
}

private struct BackLink: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        if model.step.rawValue > 0 {
            Button("上一步") { model.back() }.buttonStyle(.link)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).frame(minWidth: 96) }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: Step 1 — install location

private struct InstallStep: View {
    @ObservedObject var model: WelcomeModel

    private var path: String {
        (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        if model.installed {
            StepPage(symbol: "checkmark.circle.fill", tint: .green, title: "已安装到「应用程序」") {
                BodyText("SwitchMux 位于「应用程序」文件夹中，辅助功能授权和自动更新都能稳定工作。")
            } footer: {
                Spacer()
                PrimaryButton("继续") { model.next() }
            }
        } else {
            StepPage(symbol: "folder.badge.plus", tint: .accentColor, title: "移到「应用程序」文件夹") {
                BodyText(model.onDiskImage
                         ? "SwitchMux 正从磁盘映像中运行。macOS 不会为这里的应用保留辅助功能授权，自动更新也无法替换它。"
                         : "放在「应用程序」文件夹中，辅助功能授权才能一直有效，自动更新也才能正常工作。")
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                BodyText("点击右下角的按钮，SwitchMux 会自动复制过去并重新打开。")
                Button("也可以在访达中手动拖到「应用程序」") {
                    PrefsSupport.revealAppInFinder()
                }
                .buttonStyle(.link)
                .font(.callout)
                if let message = model.installMessage {
                    StatusLine(kind: .warning, text: message)
                }
            } footer: {
                if !model.onDiskImage {
                    Button("暂不移动") { model.next() }.buttonStyle(.link)
                }
                Spacer()
                PrimaryButton("移到「应用程序」") { model.moveToApplications() }
            }
        }
    }
}

// MARK: Step 2 — Accessibility (required)

private struct AccessibilityStep: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        if model.trusted {
            StepPage(symbol: "checkmark.circle.fill", tint: .green, title: "辅助功能已授权") {
                BodyText("SwitchMux 现在可以响应全局快捷键并切换窗口了。")
            } footer: {
                BackLink(model: model)
                Spacer()
                PrimaryButton("继续") { model.next() }
            }
        } else {
            StepPage(symbol: "hand.raised.fill", tint: .accentColor, title: "开启辅助功能权限", badge: "必需") {
                BodyText("SwitchMux 需要这项权限来监听 ⌥ 快捷键、接管 ⌘Tab 并切换窗口。")
                VStack(alignment: .leading, spacing: 6) {
                    Instruction(n: 1, text: "点击「打开系统设置」")
                    Instruction(n: 2, text: "在「辅助功能」列表中打开 SwitchMux 的开关")
                    Instruction(n: 3, text: "列表里没有？把旁边浮窗中的图标拖进列表")
                }
                StatusLine(kind: .waiting, text: "授权后会自动继续，无需重启")
                    .padding(.top, 2)
                HStack(spacing: 14) {
                    Button("在访达中显示 SwitchMux") { PrefsSupport.revealAppInFinder() }
                    Button("已打开但不生效？重新授权") { PermissionWatcher.shared.resetAndReRegister() }
                }
                .buttonStyle(.link)
                .font(.callout)
            } footer: {
                BackLink(model: model)
                Spacer()
                PrimaryButton("打开系统设置") {
                    // Registers SwitchMux in the Accessibility list now (from
                    // its final location) and shows the system alert.
                    PermissionWatcher.shared.systemPrompt()
                    PrefsSupport.guideToAccessibility()
                }
            }
        }
    }
}

private struct Instruction: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            Text(text).font(.callout)
        }
    }
}

// MARK: Step 3 — Screen Recording (optional)

private struct ScreenRecordingStep: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        let granted = model.screenRecording == .granted
        StepPage(symbol: granted ? "checkmark.circle.fill" : "rectangle.on.rectangle",
                 tint: granted ? .green : .accentColor,
                 title: granted ? "屏幕录制已授权" : "显示窗口缩略图",
                 badge: granted ? nil : "可选") {
            BodyText("按住 ⌘Tab 浏览窗口时，SwitchMux 可以显示每个窗口的实时缩略图。这需要「屏幕录制」权限；不开启也能正常切换，只是不显示缩略图。")
            switch model.screenRecording {
            case .checking: StatusLine(kind: .waiting, text: "正在检查权限…")
            case .denied: StatusLine(kind: .waiting, text: "授权后会自动识别")
            case .granted: StatusLine(kind: .ok, text: "已开启窗口缩略图")
            }
        } footer: {
            BackLink(model: model)
            Spacer()
            if granted {
                PrimaryButton("继续") { model.next() }
            } else {
                Button("跳过") { model.next() }.buttonStyle(.link)
                PrimaryButton("打开系统设置") { PrefsSupport.guideToScreenRecording() }
            }
        }
    }
}

// MARK: Step 4 — cheat-sheet

private struct FinishStep: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        StepPage(symbol: "keyboard", tint: .accentColor, title: "一切就绪，记住这三个快捷键") {
            VStack(alignment: .leading, spacing: 12) {
                ShortcutRow(keys: ["⌥", "1–9 / A–Z"], text: "打开或切换应用")
                ShortcutRow(keys: ["⌘", "Tab"], text: "浏览所有窗口", note: "快按一下回到上一个窗口")
                ShortcutRow(keys: ["⌥", "`"], text: "在同一应用的窗口间切换")
            }
            .padding(.top, 2)
            Button("打开设置，增删应用或修改按键…") {
                PreferencesWindowController.shared.showWindow(.apps)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 4)
        } footer: {
            BackLink(model: model)
            Spacer()
            PrimaryButton("开始使用") {
                SettingsStore.shared.welcomeShown = true
                WelcomeWindowController.shared.close()
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let text: String
    var note: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if i > 0 { Text("+").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                    KeyCap(label: k)
                }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 1)
    }
}
