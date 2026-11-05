import SwiftUI

/// Per-app exceptions: while one of these apps is frontmost, the App Bar
/// doesn't pop up and/or its key shortcuts are ignored.
struct SilentPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                if settings.silentApps.isEmpty {
                    Text("暂无例外应用。比如游戏或远程桌面里经常按 ⌥，可以把它们加进来。")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach($settings.silentApps) { $entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(entry.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("不弹出应用栏", isOn: $entry.hideBar)
                            .toggleStyle(.checkbox)
                        Toggle("停用应用快捷键", isOn: $entry.disableShortcuts)
                            .toggleStyle(.checkbox)
                        Button {
                            settings.silentApps.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                    }
                }
            } header: {
                Text("例外应用")
            } footer: {
                Text("这些应用在最前面时，按住激活键不会弹出应用栏；勾选「停用应用快捷键」后连 ⌥+按键 也会原样交给该应用。窗口切换（⌘Tab / ⌥`）不受影响。也可以在菜单栏图标中一键加入当前应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Menu("从运行中的应用添加") {
                        ForEach(PrefsSupport.runningApplications(), id: \.url) { app in
                            Button(app.name) { add(bundleID: app.bundleID, name: app.name) }
                                .disabled(app.bundleID.map { bid in settings.silentApps.contains { $0.bundleID == bid } } ?? true)
                        }
                    }
                    .fixedSize()
                    Button("选择应用…") {
                        for url in PrefsSupport.chooseApplications() {
                            add(bundleID: Bundle(url: url)?.bundleIdentifier,
                                name: url.deletingPathExtension().lastPathComponent)
                        }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add(bundleID: String?, name: String) {
        guard let bundleID, !settings.silentApps.contains(where: { $0.bundleID == bundleID }) else { return }
        settings.silentApps.append(SilentEntry(bundleID: bundleID, name: name))
    }
}
