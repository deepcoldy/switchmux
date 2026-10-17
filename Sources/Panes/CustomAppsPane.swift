import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class CustomAppsPaneModel: ObservableObject {
    @Published var chosenProfile: UUID?
}

struct CustomAppsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var recorder = ShortcutRecorder.shared
    @StateObject private var model = CustomAppsPaneModel()

    private var customProfiles: [Profile] {
        settings.profiles.filter { $0.mode == .custom }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var currentProfile: Profile? {
        if let id = model.chosenProfile, let p = settings.profiles.first(where: { $0.id == id }) { return p }
        if let active = settings.profiles.first(where: { $0.id == settings.activeProfile.id }),
           active.mode == .custom { return active }
        return customProfiles.first
    }

    private func binding(for profile: Profile) -> Binding<Profile> {
        let idx = settings.profiles.firstIndex { $0.id == profile.id }!
        return $settings.profiles[idx]
    }

    var body: some View {
        Group {
            if let profile = currentProfile {
                editor(profile)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有自定义配置。")
                        .foregroundStyle(.secondary)
                    Button("在「配置」中新建") {
                        PreferencesWindowController.shared.showWindow(.profiles)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { model.chosenProfile = currentProfile?.id }
    }

    @ViewBuilder
    private func editor(_ profile: Profile) -> some View {
        let p = binding(for: profile)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("配置", selection: $model.chosenProfile) {
                    ForEach(customProfiles) { cp in
                        Text(cp.name).tag(Optional(cp.id))
                    }
                }
                .frame(width: 240)
                Spacer()
            }
            .padding(12)

            Text("拖放排列应用，或从「应用程序」文件夹添加；点击按键标签可为应用单独录制快捷键。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            List {
                ForEach(p.actions) { $action in
                    row(action: $action, profileID: profile.id)
                }
                .onMove { offsets, target in
                    p.wrappedValue.actions.move(fromOffsets: offsets, toOffset: target)
                }
                .onDelete { offsets in
                    p.wrappedValue.actions.remove(atOffsets: offsets)
                }
            }
            .onDrop(of: [.application, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers, profile: p.wrappedValue)
            }

            if let msg = recorder.conflictMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Button("添加应用…") { addApps(p.wrappedValue) }
                Button("从 Dock 载入") { loadFromDock(p.wrappedValue) }
                Button("从 Switcher 载入") { loadFromSwitcher(p.wrappedValue) }
                Button("移除全部") { p.wrappedValue.actions.removeAll() }
                Spacer()
                Button("打开「应用程序」文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
            }
            .padding(12)
        }
    }

    private func row(action: Binding<ProfileAction>, profileID: UUID) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AppsMonitor.shared.icon(for: URL(fileURLWithPath: action.wrappedValue.path)))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.wrappedValue.name).font(.body)
                Text(action.wrappedValue.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if recorder.recordingActionID == action.wrappedValue.id {
                    recorder.cancel()
                } else {
                    recorder.startRecording(for: action.wrappedValue.id, profileID: profileID)
                }
            } label: {
                if recorder.recordingActionID == action.wrappedValue.id {
                    KeyBadge(text: "按下按键")
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 1.5))
                } else {
                    KeyBadge(text: action.wrappedValue.character?.uppercased() ?? "—")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
    }

    // MARK: Actions
    private func addApps(_ profile: Profile) {
        var p = profile
        let existingPaths = Set(p.actions.map(\.path))
        for url in PrefsSupport.chooseApplications() where !existingPaths.contains(url.path) {
            let ch = nextFreeCharacter(p)
            p.actions.append(PrefsSupport.makeAction(url: url, character: ch))
        }
        settings.update(p)
    }

    private func loadFromDock(_ profile: Profile) {
        var p = profile
        let existingPaths = Set(p.actions.map(\.path))
        for app in DockReader.apps() where !existingPaths.contains(app.url.path) {
            p.actions.append(PrefsSupport.makeAction(url: app.url, character: nextFreeCharacter(p)))
        }
        settings.update(p)
    }

    private func loadFromSwitcher(_ profile: Profile) {
        var p = profile
        let existingPaths = Set(p.actions.map(\.path))
        for app in PrefsSupport.runningApplications() {
            guard !existingPaths.contains(app.url.path) else { continue }
            p.actions.append(PrefsSupport.makeAction(url: app.url, character: nextFreeCharacter(p)))
        }
        settings.update(p)
    }

    private func nextFreeCharacter(_ p: Profile) -> String? {
        let used = Set(p.actions.compactMap(\.character))
        return Array(p.characters).map { String($0).lowercased() }.first { !used.contains($0) }
    }

    private func handleDrop(_ providers: [NSItemProvider], profile: Profile) -> Bool {
        var p = profile
        var found = false
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension == "app" else { return }
                DispatchQueue.main.async {
                    let existingPaths = Set(p.actions.map(\.path))
                    if !existingPaths.contains(url.path) {
                        p.actions.append(PrefsSupport.makeAction(url: url, character: nextFreeCharacter(p)))
                    }
                }
            }
            found = true
        }
        group.notify(queue: .main) { settings.update(p) }
        return found
    }
}
