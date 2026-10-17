import AppKit
import SwiftUI

struct WindowSwitcherPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = WindowSwitcherPaneModel()

    var body: some View {
        Form {
            Section("窗口缩略图切换器") {
                Toggle("启用窗口切换热键", isOn: $settings.windowSwitcherEnabled)
                Text("按住激活修饰键再按 Tab 才会弹出窗口缩略图；单独按修饰键不影响 ⌘C、⌘V 等常规快捷键。Tab / 方向键或数字选择，松开激活。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("激活热键") {
                Text("修饰键 + Tab 触发（建议与 App Bar 激活键区分开）：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    modifierToggle("⇧ Shift", .shift)
                    modifierToggle("⌃ Control", .control)
                    modifierToggle("⌥ Option", .option)
                    modifierToggle("⌘ Command", .command)
                }
                .frame(maxWidth: 420)
                if settings.windowSwitcherModifiers.intersection([.shift, .control, .option, .command]).isEmpty
                    || settings.windowSwitcherModifiers == settings.activateModifiers {
                    Text("需要至少一个修饰键，且不能与 App Bar 激活键相同。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("范围") {
                Picker("显示窗口", selection: $settings.windowScope) {
                    ForEach(WindowScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("包含最小化的窗口", isOn: $settings.includeMinimizedWindows)
                Toggle("包含已隐藏应用的窗口", isOn: $settings.includeHiddenAppWindows)
            }

            Section("外观") {
                VStack(alignment: .leading) {
                    Text("缩略图大小：\(Int(settings.windowSwitcherScale * 100))%")
                    Slider(value: $settings.windowSwitcherScale, in: 0.8...1.4, step: 0.05)
                }
            }

            Section("屏幕录制权限") {
                LabeledContent("窗口缩略图") {
                    HStack {
                        Circle()
                            .fill(model.screenRecording ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(model.screenRecording ? "已授权" : "未授权（将显示应用图标代替）")
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") { model.guide() }
                        Button("在访达中显示") { PrefsSupport.revealAppInFinder() }
                    }
                }
                Text("缩略图需要「系统设置 → 隐私与安全性 → 屏幕录制」；不授权也可正常切换。缩略图由独立的捕获子进程完成，授权后无需重启 SwitchMux，下次 ⌘+Tab 即显示真实缩略图。若列表没有 SwitchMux，请把访达中高亮的图标拖入并打开开关。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("操作速查") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按住修饰键按 Tab 呼出并前移；⇧+Tab 后移，方向键导航，数字键 1–0 直达")
                    Text("Q：退出应用　W：关闭窗口　H：隐藏应用　M：最小化")
                    Text("回车：立即激活　Esc：取消　松开修饰键：激活所选窗口")
                    Text("单独按修饰键不弹窗，不影响 ⌘C / ⌘V 等常规快捷键")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.screenRecording = ScreenCapturePermission.status
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
    }

    private func modifierToggle(_ title: String, _ flag: NSEvent.ModifierFlags) -> some View {
        let isOn = Binding<Bool>(
            get: { settings.windowSwitcherModifiers.contains(flag) },
            set: { on in
                if on { settings.windowSwitcherModifiers.insert(flag) }
                else { settings.windowSwitcherModifiers.remove(flag) }
            }
        )
        return HStack(spacing: 12) {
            Text(title)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

final class WindowSwitcherPaneModel: ObservableObject {
    @Published var screenRecording = ScreenCapturePermission.status
    private var timer: Timer?

    func guide() {
        ScreenCapturePermission.request()
        PrefsSupport.guideToScreenRecording()
        // The helper probes the live TCC state, so the indicator flips green
        // immediately after the grant without restarting SwitchMux.
        scheduleRefresh()
    }

    func startPolling() {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        if WindowCapture.isAvailable {
            WindowCapture.probe { [weak self] granted in
                DispatchQueue.main.async { self?.screenRecording = granted }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.screenRecording = ScreenCapturePermission.status
            }
        }
    }

    private func scheduleRefresh() {
        for t in [0.8, 1.6, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.poll() }
        }
    }
}
