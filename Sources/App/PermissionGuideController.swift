import AppKit
import SwiftUI
import ApplicationServices
import Combine

/// Which privacy list the guide is helping with.
enum PermissionKind {
    case accessibility
    case screenRecording

    var listName: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕与系统录音"
        }
    }
}

/// Floating guide that docks to the System Settings window while the user
/// grants a permission (Codex-style): a draggable SwitchMux icon to drop
/// straight into the list, short steps, live grant state, auto-dismiss.
final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private var panel: NSPanel?
    private let model = PermissionGuideModel()
    private var timer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var screenRecordingProbeInFlight = false

    private let size = NSSize(width: 440, height: 160)

    private init() {
        PermissionWatcher.shared.changePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGrant() }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible == true }

    private var showGeneration = 0

    func show(_ kind: PermissionKind = .accessibility) {
        showGeneration += 1
        model.kind = kind
        model.granted = false
        refreshGrant()
        if model.granted && kind == .accessibility { return }

        if panel == nil { buildPanel() }
        guard let panel else { return }
        dismissWork?.cancel()
        position(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        dismissWork?.cancel()
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.timer == nil else { return }
            panel.orderOut(nil)
        })
    }

    // MARK: State
    private var tickCount = 0
    private func tick() {
        tickCount += 1
        position(animated: true)
        // Accessibility is cheap to query; Screen Recording needs the helper.
        if model.kind == .accessibility || tickCount % 4 == 0 { refreshGrant() }
    }

    private func refreshGrant() {
        switch model.kind {
        case .accessibility:
            setGranted(PrefsSupport.accessibilityTrusted)
        case .screenRecording:
            guard WindowCapture.isAvailable, !screenRecordingProbeInFlight else {
                if !WindowCapture.isAvailable { setGranted(ScreenCapturePermission.status) }
                return
            }
            screenRecordingProbeInFlight = true
            let generation = showGeneration
            WindowCapture.probe { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.screenRecordingProbeInFlight = false
                    // Ignore a probe that started before the guide was re-shown
                    // (possibly for the other permission).
                    guard self.showGeneration == generation, self.model.kind == .screenRecording else { return }
                    self.setGranted(granted)
                }
            }
        }
    }

    private func setGranted(_ granted: Bool) {
        guard granted != model.granted else { return }
        model.granted = granted
        if granted {
            dismissWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    // MARK: Panel
    private func buildPanel() {
        let view = PermissionGuideView(
            model: model,
            reopenSettings: { [weak self] in
                guard let self else { return }
                switch self.model.kind {
                case .accessibility: PrefsSupport.openAccessibilitySettings()
                case .screenRecording: PrefsSupport.openScreenRecordingSettings()
                }
            },
            reveal: { PrefsSupport.revealAppInFinder() },
            reset: { PermissionWatcher.shared.resetAndReRegister() },
            close: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)

        let effect = NSVisualEffectView(frame: host.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(host)

        let panel = NSPanel(contentRect: effect.bounds,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = effect
        self.panel = panel
    }

    /// System Settings' sidebar has a fixed width; the privacy list lives in
    /// the content pane to its right (inset by the pane's margins).
    static let settingsSidebarWidth: CGFloat = 252
    static let settingsContentInsetRight: CGFloat = 20

    /// Content-pane span (the list and its +/− bar) of a Settings window.
    static func contentPane(of settings: NSRect) -> (minX: CGFloat, maxX: CGFloat) {
        let sidebar = min(settingsSidebarWidth, settings.width * 0.45)
        return (settings.minX + sidebar, settings.maxX - settingsContentInsetRight)
    }

    /// Docks right under the list in System Settings: left edge flush with
    /// the list (so the icon and its arrow sit below the +/− bar it's dropped
    /// next to), or inside the window's bottom edge if there's no room below.
    /// Falls back to the top-right of the main screen.
    private func position(animated: Bool) {
        guard let panel else { return }
        var origin: NSPoint
        if let settings = Self.settingsWindowFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let pane = Self.contentPane(of: settings)
            let gap: CGFloat = 8
            // Prefer aligning with the list's left edge; if the pane is
            // narrower than the panel, right-align with the pane instead.
            let x = pane.maxX - pane.minX >= size.width ? pane.minX : pane.maxX - size.width
            origin = NSPoint(x: x, y: settings.minY - size.height - gap)
            if origin.y < vf.minY + 8 {
                origin.y = settings.minY + 16   // overlap the bottom of the window instead
            }
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            model.docked = true
        } else {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let vf = screen.visibleFrame
            origin = NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16)
            model.docked = false
        }
        let target = NSRect(origin: origin, size: size)
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true, animate: animated && panel.isVisible)
    }

    /// Debug: current Settings window / content pane / panel frames.
    func debugFrames() -> String {
        let settings = Self.settingsWindowFrame()
        let pane = settings.map { Self.contentPane(of: $0) }
        return "settings=\(settings.map { "\($0)" } ?? "nil") pane=\(pane.map { "\($0.minX)…\($0.maxX)" } ?? "nil") panel=\(panel?.frame ?? .zero)"
    }

    /// Frame of the frontmost System Settings window in AppKit coordinates.
    static func settingsWindowFrame() -> NSRect? {
        let owners: Set<String> = ["System Settings", "System Preferences", "系统设置", "系统偏好设置"]
        let bundleIDs: Set<String> = ["com.apple.systempreferences"]
        let settingsPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { bundleIDs.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier))
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        // Front-to-back order: the first matching normal window is the one in use.
        for w in info {
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? -1
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard settingsPIDs.contains(pid) || owners.contains(owner),
                  w[kCGWindowLayer as String] as? Int == 0,
                  let dict = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: dict as! CFDictionary),
                  r.width > 300, r.height > 200 else { continue }
            // CG global coords have a top-left origin on the primary display.
            return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        return nil
    }

    /// Debug hook: rasterize the guide to PNG.
    func smokeDump(to path: String) {
        try? debugFrames().write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class PermissionGuideModel: ObservableObject {
    @Published var kind: PermissionKind = .accessibility
    @Published var granted = false
    @Published var docked = false
    @Published var nudge = false
}

private struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel
    let reopenSettings: () -> Void
    let reveal: () -> Void
    let reset: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: model.nudge ? -4 : 2)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: model.nudge)
                    .opacity(model.granted ? 0 : 1)
                AppDragSource()
                    .frame(width: 64, height: 64)
                Text(model.granted ? "已授权" : "拖我")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.granted ? Color.green : Color.secondary)
            }
            .frame(width: 76)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if model.granted {
                        Label("SwitchMux 已获得\(model.kind.listName)权限", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("允许 SwitchMux 使用\(model.kind.listName)")
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 3) {
                    step(1, model.docked ? "把左边的图标拖进上方的「\(model.kind.listName)」列表" : "打开「系统设置」的「\(model.kind.listName)」，把左边的图标拖进列表")
                    step(2, "打开 SwitchMux 右侧的开关")
                    step(3, "列表里已有 SwitchMux 且开着却不生效？点下面的「重新添加」")
                }
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))

                HStack(spacing: 10) {
                    Button("打开系统设置", action: reopenSettings)
                    if model.kind == .accessibility {
                        Button("重新添加", action: reset)
                            .help("清除 SwitchMux 旧的授权记录（例如更新后签名变化）并重新加入列表")
                    } else {
                        Button("在访达中显示", action: reveal)
                    }
                    Spacer()
                    if !model.granted {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("等待授权").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10.5))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { model.nudge = true }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The SwitchMux icon as a real file drag source: dropping it on the
/// System Settings privacy list adds the app, exactly like dragging it from
/// Finder.
private struct AppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppDragSourceView { AppDragSourceView() }
    func updateNSView(_ nsView: AppDragSourceView, context: Context) {}
}

final class AppDragSourceView: NSView, NSDraggingSource {
    private let imageView = NSImageView()

    static var appURL: URL {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : url.deletingLastPathComponent()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.image = NSWorkspace.shared.icon(forFile: Self.appURL.path)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        toolTip = "拖到系统设置的权限列表中"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Self.appURL as NSURL)
        item.setDraggingFrame(bounds, contents: imageView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
