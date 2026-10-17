import SwiftUI

struct SilentPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Text("如果当前最前面的应用在此列表中，按下激活热键时不会显示 App Bar。")
            }
            Section("静默应用") {
                List {
                    ForEach($settings.silentApps) { $entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.body)
                                Text(entry.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("不显示", isOn: $entry.hideBar)
                                .labelsHidden()
                            Toggle("禁用快捷键", isOn: $entry.disableShortcuts)
                                .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        settings.silentApps.remove(atOffsets: offsets)
                    }
                }
                .frame(height: 220)
                HStack {
                    Menu("从运行中的应用添加") {
                        ForEach(PrefsSupport.runningApplications(), id: \.url) { app in
                            Button(app.name) {
                                guard let bid = app.bundleID,
                                      !settings.silentApps.contains(where: { $0.bundleID == bid }) else { return }
                                settings.silentApps.append(
                                    SilentEntry(bundleID: bid, name: app.name))
                            }
                        }
                    }
                    Button("从应用程序文件夹添加") {
                        for url in PrefsSupport.chooseApplications() {
                            guard let bid = Bundle(url: url)?.bundleIdentifier,
                                  !settings.silentApps.contains(where: { $0.bundleID == bid }) else { continue }
                            settings.silentApps.append(
                                SilentEntry(bundleID: bid, name: url.deletingPathExtension().lastPathComponent))
                        }
                    }
                }
            }
            Section {
                Text("💡 勾选「禁用快捷键」后，在该应用中即使显示 App Bar 也忽略数字/字母快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
