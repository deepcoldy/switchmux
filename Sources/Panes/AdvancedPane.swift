import AppKit
import SwiftUI

final class AdvancedPaneModel: ObservableObject {
    @Published var showModifierWarning = false
}

struct AdvancedPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = AdvancedPaneModel()

    private let hideAfterOptions: [(label: String, value: Double)] = [
        ("永不", 0), ("2 秒", 2), ("3 秒", 3), ("5 秒", 5)
    ]

    var body: some View {
        Form {
            Section("激活热键") {
                Text("勾选一个或多个修饰键作为激活热键：")
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
                if model.showModifierWarning {
                    Text("至少需要设置一个修饰键")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("双击激活热键可临时停用/启用", isOn: $settings.doublePressToggle)
            }

            Section("显示时机") {
                Picker("显示延迟：", selection: $settings.displayDelay) {
                    Text("立即").tag(0.0)
                    Text("0.15 秒").tag(0.15)
                    Text("0.25 秒").tag(0.25)
                    Text("0.5 秒").tag(0.5)
                    Text("1 秒").tag(1.0)
                    Text("永不（仅快捷键，不显示 App Bar）").tag(-1.0)
                }
                .pickerStyle(.menu)
                Picker("显示后自动隐藏：", selection: $settings.hideAfter) {
                    ForEach(hideAfterOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("显示在：", selection: $settings.showOnActiveScreen) {
                    Text("当前活跃屏幕").tag(true)
                    Text("主屏幕").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            Section("切换行为") {
                Toggle("当前应用已在最前时，再按一次则隐藏它", isOn: $settings.hideOnRepeat)
                Toggle("悬停在应用上松开激活键即可切换", isOn: $settings.switchByReleasing)
            }
        }
        .formStyle(.grouped)
    }

    private func modifierToggle(_ title: String, _ flag: NSEvent.ModifierFlags) -> some View {
        let isOn = Binding<Bool>(
            get: { settings.activateModifiers.contains(flag) },
            set: { on in
                if on {
                    settings.activateModifiers.insert(flag)
                } else {
                    settings.activateModifiers.remove(flag)
                }
                model.showModifierWarning = settings.activateModifiers
                    .intersection([.shift, .control, .option, .command]).isEmpty
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
