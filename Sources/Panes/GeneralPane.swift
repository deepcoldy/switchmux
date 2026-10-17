import AppKit
import SwiftUI

final class GeneralPaneModel: ObservableObject {
    @Published var trusted = PrefsSupport.accessibilityTrusted
    @Published var launchAtLogin = SettingsStore.shared.launchAtLogin
}

struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = GeneralPaneModel()

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动 SwitchMux", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { newValue in
                        settings.launchAtLogin = newValue
                    }
            }
            Section("菜单栏") {
                Toggle("显示状态栏图标", isOn: $settings.showStatusIcon)
                Text("如果不在菜单栏显示图标，再次启动 SwitchMux 会打开本设置窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("权限") {
                LabeledContent("辅助功能权限") {
                    HStack {
                        Circle()
                            .fill(model.trusted ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(model.trusted ? "已授权" : "未授权（按住热键需要此权限）")
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") {
                            PrefsSupport.guideToAccessibility()
                        }
                        Button("在访达中显示") {
                            PrefsSupport.revealAppInFinder()
                        }
                    }
                }
                if !model.trusted {
                    Text("如果辅助功能列表中没有 SwitchMux，请在访达中把它的图标直接拖入系统设置的列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("支持") {
                Button("重新查看欢迎页") {
                    WelcomeWindowController.shared.showWindow()
                }
                LabeledContent("配置同步") {
                    Text(ConfigSync.shared.locationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("SwitchMux 1.0.0（应用与窗口快速切换器）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.trusted = PrefsSupport.accessibilityTrusted
            model.launchAtLogin = settings.launchAtLogin
        }
    }
}
