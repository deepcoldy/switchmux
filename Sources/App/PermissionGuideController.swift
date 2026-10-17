import AppKit
import SwiftUI
import ApplicationServices
import Combine

/// Compact always-on-top guide shown beside System Settings while the user
/// grants Accessibility: app icon, drag instructions, reveal-in-Finder action,
/// live grant state, auto-dismiss.
final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<PermissionGuideView>?
    private let model = PermissionGuideModel()
    private var repositionTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {
        PermissionWatcher.shared.changePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                self?.model.trusted = trusted
                if trusted { self?.scheduleDismiss() }
            }
            .store(in: &cancellables)
    }
    private var cancellables = Set<AnyCancellable>()

    func show() {
        model.trusted = PrefsSupport.accessibilityTrusted
        if model.trusted { return }

        if panel == nil { buildPanel() }
        guard let panel else { return }
        dismissWorkItem?.cancel()
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }

        repositionTimer?.invalidate()
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.positionPanel()
        }
    }

    func hide() {
        dismissWorkItem?.cancel()
        repositionTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ [weak panel] ctx in
            ctx.duration = 0.18
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func buildPanel() {
        let view = PermissionGuideView(model: model,
                                       reveal: { PrefsSupport.revealAppInFinder() },
                                       reopenSettings: { PrefsSupport.openAccessibilitySettings() },
                                       close: { [weak self] in self?.hide() })
        let size = NSSize(width: 348, height: 184)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)

        let effect = NSVisualEffectView(frame: host.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
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
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .default
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = effect
        self.panel = panel
        self.hosting = host
    }

    // MARK: Placement beside the System Settings window
    private func positionPanel() {
        guard let panel else { return }
        let size = panel.frame.size
        let margin: CGFloat = 16

        if let settingsFrame = settingsWindowFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(settingsFrame) }) {
            let vf = screen.visibleFrame
            var origin = NSPoint()
            // Prefer right of Settings; fall back to left; else top-trailing.
            if settingsFrame.maxX + margin + size.width <= vf.maxX {
                origin.x = settingsFrame.maxX + margin
            } else if settingsFrame.minX - margin - size.width >= vf.minX {
                origin.x = settingsFrame.minX - margin - size.width
            } else {
                origin.x = vf.maxX - size.width - margin
            }
            origin.y = min(max(settingsFrame.midY - size.height / 2, vf.minY + margin),
                           vf.maxY - size.height - margin)
            panel.setFrameOrigin(origin)
            return
        }

        guard let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = main.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - margin,
                                    y: vf.maxY - size.height - margin))
    }

    /// Debug hook: rasterize the guide to PNG.
    func smokeDump(to path: String) {
        guard let panel, let view = panel.contentView else { return }
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private func settingsWindowFrame() -> NSRect? {
        let owners: Set<String> = ["System Settings", "System Preferences"]
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: NSRect?
        var bestArea: CGFloat = 0
        for w in info {
            guard let owner = w[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  w[kCGWindowLayer as String] as? Int == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }
            let r = NSRect(x: x, y: y, width: width, height: height)
            let area = width * height
            if area > bestArea { best = r; bestArea = area }
        }
        guard let topLeft = best,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(topLeft) }) else { return best }
        // Core Graphics uses top-left origin; flip to AppKit bottom-left.
        return NSRect(x: topLeft.minX,
                      y: screen.frame.maxY - topLeft.maxY,
                      width: topLeft.width, height: topLeft.height)
    }
}

final class PermissionGuideModel: ObservableObject {
    @Published var trusted = false
    @Published var bounce = false
}

private struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel
    let reveal: () -> Void
    let reopenSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .offset(y: model.bounce ? -3 : 0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: model.bounce)
                VStack(alignment: .leading, spacing: 2) {
                    Text("授权辅助功能").font(.system(size: 14, weight: .semibold))
                    Text("无需重启，授权后立即生效")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("点「在访达中显示」，让 SwitchMux 在访达中高亮", systemImage: "1.circle.fill")
                Label("把 SwitchMux 图标拖入系统设置的辅助功能列表", systemImage: "2.circle.fill")
                Label("打开列表项右侧的开关", systemImage: "3.circle.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.primary.opacity(0.9))
            .labelStyle(GuideStepStyle())

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    reveal()
                    reopenSettings()
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)

                Spacer()

                HStack(spacing: 5) {
                    if model.trusted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已授权").foregroundStyle(.green)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("等待授权…").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .onAppear { model.bounce = true }
    }
}

private struct GuideStepStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 7) {
            configuration.icon
                .font(.system(size: 11.5))
                .foregroundStyle(.tint)
            configuration.title
        }
    }
}
