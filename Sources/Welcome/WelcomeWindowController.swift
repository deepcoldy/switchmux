import AppKit
import SwiftUI

final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "欢迎使用 SwitchMux"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let view = WelcomeView()
            .frame(width: 480, height: 500)
        let host = NSHostingView(rootView: view)
        window.contentView = host
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil as Any?)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func smokeDump(to path: String) {
        guard let view = window?.contentView else { return }
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class WelcomeModel: ObservableObject {
    @Published var trusted = PrefsSupport.accessibilityTrusted
    private var timer: Timer?

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let now = PrefsSupport.accessibilityTrusted
            if now != self?.trusted { self?.trusted = now }
        }
    }
}

private struct WelcomeView: View {
    @StateObject private var model = WelcomeModel()

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("欢迎使用 SwitchMux")
                .font(.system(size: 20, weight: .semibold))
            VStack(spacing: 4) {
                Text("按住 ⌥ Option 键并按下数字键，开始使用 SwitchMux。")
                Text("再按一次数字键可隐藏当前应用；按住 Option 悬停后松开也能切换。")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            if !model.trusted {
                VStack(spacing: 8) {
                    Text("需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权 SwitchMux")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button {
                        PrefsSupport.guideToAccessibility()
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .controlSize(.large)
                    Button {
                        PrefsSupport.revealAppInFinder()
                    } label: {
                        Label("在访达中显示 SwitchMux", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    Text("如果列表中没有 SwitchMux，请在访达中把它的图标直接拖入辅助功能列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            } else {
                Label("辅助功能权限已授权", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Spacer()
            Button("开始使用") {
                SettingsStore.shared.welcomeShown = true
                WelcomeWindowController.shared.close()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            Text("可以稍后在「设置 → 高级」中修改激活键。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            model.trusted = PrefsSupport.accessibilityTrusted
            model.startPolling()
        }
    }
}
