import AppKit
import SwiftUI

final class GeneralPaneModel: ObservableObject {
    @Published var trusted = PrefsSupport.accessibilityTrusted
    @Published var launchAtLogin = SettingsStore.shared.launchAtLogin
    @Published var refreshing = false
    @Published var refreshResult: String?

    func refreshFromCloud() {
        refreshing = true
        refreshResult = nil
        ConfigSync.shared.refreshFromCloud { [weak self] outcome in
            self?.refreshing = false
            self?.refreshResult = outcome.message
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var sync = ConfigSync.shared
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
            }
            syncSection
            Section {
                Text("SwitchMux \(AppInfo.shortVersion)（应用与窗口快速切换器）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.trusted = PrefsSupport.accessibilityTrusted
            model.launchAtLogin = settings.launchAtLogin
            if sync.usesICloud { sync.requestSync() }
        }
    }

    private var syncSection: some View {
        Section("配置同步") {
            LabeledContent("位置") {
                Text(sync.locationDescription).foregroundStyle(.secondary)
            }
            if sync.usesICloud {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        if sync.phase == .syncing { ProgressView().controlSize(.small) }
                        Text(syncStatus.text)
                            .foregroundStyle(syncStatus.warning ? Color.orange : Color.secondary)
                    }
                }
                if let edit = sync.lastEdit {
                    LabeledContent("最近修改") {
                        Text([Self.format(edit.date), edit.device].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("从 iCloud 获取最新配置") { model.refreshFromCloud() }
                        .disabled(model.refreshing)
                    if let result = model.refreshResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if FileManager.default.fileExists(atPath: sync.backupDirectory.path) {
                        Button("显示备份") { NSWorkspace.shared.open(sync.backupDirectory) }
                    }
                }
                if let writer = sync.olderBuildWriter {
                    Text("iCloud 中的配置最近由旧版 SwitchMux（\(writer)）写入。旧版会覆盖其他 Mac 的修改，请把所有 Mac 更新到最新版。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var syncStatus: (text: String, warning: Bool) {
        switch sync.phase {
        case .localOnly: return ("仅本机", false)
        case .syncing: return ("正在同步…", false)
        case .waiting(let reason): return (reason, false)
        case .failed(let reason): return ("同步失败：\(reason)", true)
        case .idle:
            guard let date = sync.lastSynced else { return ("等待同步", false) }
            return ("已同步（\(Self.format(date))）", false)
        }
    }

    private static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
