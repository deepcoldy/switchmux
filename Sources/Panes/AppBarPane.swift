import SwiftUI

/// App Bar behaviour + appearance (formerly the "高级" and "外观" panes).
struct AppBarPane: View {
    @EnvironmentObject var settings: SettingsStore

    private let delays: [(String, Double)] = [
        ("立即", 0), ("0.15 秒", 0.15), ("0.25 秒", 0.25), ("0.5 秒", 0.5), ("1 秒", 1),
        ("从不（只用快捷键，不显示应用栏）", -1),
    ]
    private let hideAfterOptions: [(String, Double)] = [
        ("不自动隐藏", 0), ("2 秒后", 2), ("3 秒后", 3), ("5 秒后", 5),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("启用应用栏", isOn: $settings.enabled)
                LabeledContent("激活键") {
                    ModifierPicker(flags: $settings.activateModifiers)
                }
                Toggle("连按两次激活键可暂停 / 恢复应用栏", isOn: $settings.doublePressToggle)
            } header: {
                Text("激活")
            } footer: {
                Text("按住 \(settings.activateModifiers.spelledOut) 时显示应用栏；单独按住不会影响其它组合键（如 ⌥←）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("显示") {
                Picker("按住多久后显示", selection: $settings.displayDelay) {
                    ForEach(delays, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("自动隐藏", selection: $settings.hideAfter) {
                    ForEach(hideAfterOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("显示在", selection: $settings.showOnActiveScreen) {
                    Text("当前窗口所在屏幕").tag(true)
                    Text("主屏幕").tag(false)
                }
                .pickerStyle(.segmented)
            }

            Section("切换") {
                Toggle("按下已在最前的应用的按键时，隐藏它", isOn: $settings.hideOnRepeat)
                Toggle("鼠标悬停在图标上松开激活键，也会切换到该应用", isOn: $settings.switchByReleasing)
            }

            Section("外观") {
                slider("大小", value: $settings.barSizeScale, range: 0.7...1.4, step: 0.05) { "\(Int($0 * 100))%" }
                slider("不透明度", value: $settings.barOpacity, range: 0.3...1.0, step: 0.05) { "\(Int($0 * 100))%" }
                slider("当前应用高亮边框", value: $settings.borderWidth, range: 0...6, step: 1) { "\(Int($0)) px" }
                Picker("垂直位置", selection: $settings.verticalPosition) {
                    ForEach(BarVerticalPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("水平位置", selection: $settings.horizontalPosition) {
                    ForEach(BarHorizontalPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    Button("预览") { AppBarController.shared.preview() }
                    Button("恢复默认外观") {
                        settings.barSizeScale = SettingsStore.defaultBarSizeScale
                        settings.barOpacity = SettingsStore.defaultBarOpacity
                        settings.borderWidth = SettingsStore.defaultBorderWidth
                        settings.verticalPosition = .middle
                        settings.horizontalPosition = .center
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                    .frame(maxWidth: 260)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
