import AppKit
import SwiftUI

struct WindowSwitcherPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = WindowSwitcherPaneModel()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.windowSwitcherEnabled) {
                    Text("\(settings.windowSwitcherModifier.symbol) Tab 切换所有窗口")
                }
                if settings.windowSwitcherEnabled {
                    Picker("修饰键", selection: $settings.windowSwitcherModifier) {
                        ForEach(SwitcherModifier.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("显示", selection: $settings.windowScope) {
                        ForEach(WindowScope.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("包含最小化的窗口", isOn: $settings.includeMinimizedWindows)
                    Toggle("包含已隐藏应用的窗口", isOn: $settings.includeHiddenAppWindows)
                }
            } header: {
                Text("窗口切换")
            } footer: {
                Text(windowFooter).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.appWindowSwitcherEnabled) {
                    Text("\(settings.appWindowSwitcherModifier.symbol) ` 在当前应用的窗口之间切换")
                }
                if settings.appWindowSwitcherEnabled {
                    Picker("修饰键", selection: $settings.appWindowSwitcherModifier) {
                        ForEach(SwitcherModifier.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("同一应用的窗口")
            } footer: {
                Text("` 是 Tab 上方的键。快速按一下切到该应用上一个使用的窗口，按住可浏览全部窗口；加 ⇧ 反向。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("缩略图") {
                LabeledContent("大小") {
                    HStack {
                        Slider(value: $settings.windowSwitcherScale, in: 0.8...1.4, step: 0.05)
                            .frame(maxWidth: 260)
                        Text("\(Int(settings.windowSwitcherScale * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("屏幕录制权限") {
                    HStack {
                        Circle()
                            .fill(model.screenRecording ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(model.screenRecording ? "已授权" : "未授权（显示应用图标）")
                            .foregroundStyle(.secondary)
                        if !model.screenRecording {
                            Button("去授权") { model.guide() }
                        }
                    }
                }
            }

            Section("切换器中的按键") {
                VStack(alignment: .leading, spacing: 4) {
                    shortcut("Tab / ⇧Tab、方向键", "移动选择")
                    shortcut("1 – 0", "直接选中第 1–10 个")
                    shortcut("松开修饰键 / 回车 / 点击", "切换到所选窗口")
                    shortcut("Esc", "取消")
                    shortcut("Q · W · H · M", "退出应用 · 关闭窗口 · 隐藏应用 · 最小化")
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var windowFooter: String {
        guard settings.windowSwitcherEnabled else {
            return "已关闭：⌘Tab 由系统原生切换器处理。"
        }
        if settings.windowSwitcherModifier == .command {
            return "SwitchMux 会接管系统的 ⌘Tab：快速按一下切换到上一个窗口，按住可浏览所有窗口的缩略图。关闭此项或退出 SwitchMux 会立即恢复系统 ⌘Tab。"
        }
        return "系统 ⌘Tab 保持不变；\(settings.windowSwitcherModifier.symbol)Tab 打开 SwitchMux 的窗口切换器。"
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).fontWeight(.medium).frame(width: 170, alignment: .leading)
            Text(action).foregroundStyle(.secondary)
        }
    }
}

final class WindowSwitcherPaneModel: ObservableObject {
    @Published var screenRecording = ScreenCapturePermission.status
    private var timer: Timer?

    func guide() {
        PrefsSupport.guideToScreenRecording()
        for t in [0.8, 1.6, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.poll() }
        }
    }

    func startPolling() {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// The helper probes the live TCC state, so the indicator flips green
    /// right after the grant without restarting SwitchMux.
    private func poll() {
        if WindowCapture.isAvailable {
            WindowCapture.probe { [weak self] granted in
                DispatchQueue.main.async { self?.screenRecording = granted }
            }
        } else {
            screenRecording = ScreenCapturePermission.status
        }
    }
}
