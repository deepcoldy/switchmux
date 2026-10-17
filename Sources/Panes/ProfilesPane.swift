import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ProfilesPaneModel: ObservableObject {
    @Published var selection: UUID?
}

struct ProfilesPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = ProfilesPaneModel()

    private var ordered: [Profile] {
        settings.profiles.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var selectedProfile: Binding<Profile>? {
        guard let selection = model.selection,
              let idx = settings.profiles.firstIndex(where: { $0.id == selection }) else { return nil }
        return $settings.profiles[idx]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Profile list
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(ordered) { p in
                        HStack {
                            Image(systemName: modeIcon(p.mode))
                            Text(p.name)
                                .lineLimit(1)
                        }
                        .tag(p.id)
                    }
                }
                .frame(width: 220)
                HStack {
                    Button {
                        let p = settings.addProfile(mode: .custom)
                        model.selection = p.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let p = selectedProfile?.wrappedValue { settings.duplicate(p) }
                    } label: { Image(systemName: "doc.on.doc") }
                    .disabled(model.selection == nil)
                    Button {
                        if let p = selectedProfile?.wrappedValue, settings.profiles.count > 1 {
                            settings.delete(p)
                            model.selection = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(model.selection == nil || settings.profiles.count <= 1)
                    Spacer()
                    Menu {
                        Button("导出配置…") { exportProfile() }
                        Button("导入配置…") { importProfiles() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.selection == nil)
                }
                .padding(8)
                .frame(width: 220)
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Detail
            if let p = selectedProfile {
                detail(p)
            } else {
                ContentUnavailableViewCompat()
            }
        }
        .onAppear { model.selection = settings.activeProfile.id }
    }

    @ViewBuilder
    private func detail(_ p: Binding<Profile>) -> some View {
        Form {
            Section("配置名称") {
                TextField("名称", text: p.name)
            }
            Section("模式") {
                Picker("模式", selection: p.mode) {
                    ForEach(AppMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(p.wrappedValue.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch p.wrappedValue.mode {
            case .dock:
                Section("Dock 选项") {
                    Toggle("将 Finder 作为第一个应用", isOn: p.includeFinder)
                }
            case .switcher:
                Section("过滤应用") {
                    Text("此列表中的应用不会出现在 Switcher 模式中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    filterEditor
                }
            case .custom:
                Section("自定义应用") {
                    Text("在「应用」标签页中添加和排列应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开「应用」标签页") {
                        PreferencesWindowController.shared.showWindow(.customApps)
                    }
                }
            }

            Section("快捷键字符") {
                TextField("字符（从左到右依次分配）", text: p.characters)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                    presetButton("数字", "1234567890", p)
                    presetButton("字母", "QWERTYUIOP", p)
                    presetButton("数字+字母", "1234567890QWERTYUIOP", p)
                    presetButton("左手区", "ASDFGHZXCV", p)
                    presetButton("右手区", "YUIOPHJKLM", p)
                    presetButton("全尺寸", "1234567890QWERTYUIOPASDFGH", p)
                }
                Text("按住激活键时，按下对应字符即可切换到该应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func presetButton(_ title: String, _ chars: String, _ p: Binding<Profile>) -> some View {
        Button(title) { p.wrappedValue.characters = chars }
    }

    private var filterEditor: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(settings.switcherFilter, id: \.self) { bid in
                    Text(bid).font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in
                    settings.switcherFilter.remove(atOffsets: offsets)
                }
            }
            .frame(height: 110)
            HStack {
                Menu("从运行中的应用添加") {
                    ForEach(PrefsSupport.runningApplications(), id: \.url) { app in
                        Button(app.name) {
                            if let bid = app.bundleID, !settings.switcherFilter.contains(bid) {
                                settings.switcherFilter.append(bid)
                            }
                        }
                    }
                }
                Button("从应用程序文件夹添加") {
                    PrefsSupport.chooseApplications().forEach { url in
                        guard let bid = Bundle(url: url)?.bundleIdentifier,
                              !settings.switcherFilter.contains(bid) else { return }
                        settings.switcherFilter.append(bid)
                    }
                }
            }
        }
    }

    private func modeIcon(_ mode: AppMode) -> String {
        switch mode {
        case .dock: return "dock.rectangle"
        case .switcher: return "app"
        case .custom: return "slider.horizontal.3"
        }
    }

    // MARK: Export / import
    private func exportProfile() {
        guard let p = selectedProfile?.wrappedValue else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).switchmux.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? JSONEncoder().encode([p]) {
            try? data.write(to: url)
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              var imported = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        let maxOrder = settings.profiles.map(\.sortOrder).max() ?? -1
        for i in imported.indices {
            imported[i].id = UUID()
            imported[i].sortOrder = maxOrder + i + 1
        }
        settings.profiles.append(contentsOf: imported)
        if let first = imported.first { model.selection = first.id }
    }
}

private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("选择左侧的配置")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
