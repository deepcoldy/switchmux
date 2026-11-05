import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Command Line Tools ship without the SwiftUI macro plugin, so view state
/// lives in an ObservableObject instead of @State.
final class AppsPaneModel: ObservableObject {
    @Published var selection = Set<UUID>()
    @Published var dropTargeted = false
}

/// The single app list shown in the App Bar: add (pick / Finder / Dock /
/// running / drag-in), reorder, bind keys, remove.
struct AppsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @StateObject private var model = AppsPaneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ZStack {
                if settings.apps.isEmpty {
                    emptyState
                } else {
                    list
                }
                if model.dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted, perform: handleDrop)

            if let msg = recorder.message {
                Label(msg, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear { recorder.cancel() }
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("按住")
                    KeyBadge(text: settings.activateModifiers.symbols, wide: true)
                    Text("再按应用右侧的按键，即可打开、切换或隐藏它")
                }
                .font(.system(size: 13, weight: .medium))
                Text("点击按键可重新录制（Delete 清除，Esc 取消）；拖动行可排序；也可以把 .app 直接拖进来。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("更改激活键…") { PreferencesWindowController.shared.showWindow(.appBar) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: List
    private var list: some View {
        List(selection: $model.selection) {
            ForEach($settings.apps) { $entry in
                AppRow(entry: $entry,
                       recording: recorder.recordingAppID == entry.id,
                       onRecord: { recorder.toggle(entry.id) },
                       onRemove: { remove([entry.id]) })
                    .tag(entry.id)
                    .contextMenu {
                        Button("录制快捷键") { recorder.start(entry.id) }
                        Button("清除快捷键") { settings.bind(appID: entry.id, keyCode: nil, character: nil) }
                        Divider()
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        Divider()
                        Button("移除") { remove([entry.id]) }
                    }
            }
            .onMove { offsets, target in settings.apps.move(fromOffsets: offsets, toOffset: target) }
        }
        .onDeleteCommand { remove(model.selection) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有添加应用").font(.headline)
            Text("从下面选一种方式开始，或把应用从访达拖到这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("导入 Dock 中的应用") { addDockApps(includeFinder: true) }
                    .buttonStyle(.borderedProminent)
                Button("添加 Finder") { settings.addApps([DockReader.finderURL]) }
                Button("选择应用…") { settings.addApps(PrefsSupport.chooseApplications()) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer
    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("选择应用…") { settings.addApps(PrefsSupport.chooseApplications()) }
                Button("添加 Finder") { settings.addApps([DockReader.finderURL]) }
                    .disabled(settings.containsApp(path: DockReader.finderURL.path))
                Divider()
                Menu("Dock 中的应用") {
                    Button("全部添加（含 Finder）") { addDockApps(includeFinder: true) }
                    Divider()
                    ForEach(DockReader.apps(), id: \.url) { app in
                        Button(app.name) { settings.addApps([app.url]) }
                            .disabled(settings.containsApp(path: app.url.path))
                    }
                }
                Menu("正在运行的应用") {
                    ForEach(PrefsSupport.runningApplications(), id: \.url) { app in
                        Button(app.name) { settings.addApps([app.url]) }
                            .disabled(settings.containsApp(path: app.url.path))
                    }
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                remove(model.selection)
            } label: {
                Label("移除", systemImage: "minus")
            }
            .disabled(model.selection.isEmpty)

            Spacer()

            Text("\(settings.apps.count) 个应用")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("按顺序重新分配按键（1–0、Q–P…）") { settings.reassignKeys() }
                Button("清除全部按键") { settings.clearKeys() }
                Divider()
                Button("导出列表…") { exportList() }
                Button("导入列表…") { importList() }
                Divider()
                Button("清空列表") {
                    recorder.cancel()
                    settings.apps.removeAll()
                    model.selection.removeAll()
                }
                .disabled(settings.apps.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Actions
    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let rec = recorder.recordingAppID, ids.contains(rec) { recorder.cancel() }
        settings.apps.removeAll { ids.contains($0.id) }
        model.selection.subtract(ids)
    }

    private func addDockApps(includeFinder: Bool) {
        var urls: [URL] = includeFinder ? [DockReader.finderURL] : []
        urls += DockReader.apps().map(\.url)
        settings.addApps(urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension == "app" {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { settings.addApps(urls) }
        return !providers.isEmpty
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SwitchMux 应用列表.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings.apps) { try? data.write(to: url) }
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        // Accept both the new list format and ≤ 1.1 profile exports.
        var imported: [AppEntry] = []
        if let list = try? JSONDecoder().decode([AppEntry].self, from: data) {
            imported = list
        } else if let profiles = try? JSONDecoder().decode([LegacyProfile].self, from: data) {
            imported = profiles.flatMap(\.actions)
        }
        guard !imported.isEmpty else { return }
        var list = settings.apps
        for var entry in imported where !list.contains(where: { $0.path == entry.path }) {
            entry.id = UUID()
            if let code = entry.triggerKeyCode, list.contains(where: { $0.triggerKeyCode == code }) {
                entry.keyCode = nil
                entry.character = nil
            }
            list.append(entry)
        }
        settings.apps = list
    }
}

private struct AppRow: View {
    @Binding var entry: AppEntry
    let recording: Bool
    let onRecord: () -> Void
    let onRemove: () -> Void

    private var exists: Bool { FileManager.default.fileExists(atPath: entry.path) }
    private var unresolved: Bool { entry.character != nil && entry.triggerKeyCode == nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
            Image(nsImage: AppsMonitor.shared.icon(for: entry.url))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(exists ? entry.path : "找不到该应用：\(entry.path)")
                    .font(.caption)
                    .foregroundStyle(exists ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onRecord) {
                if recording {
                    Text("按下按键…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    KeyBadge(text: entry.character ?? "＋", dimmed: entry.character == nil)
                        .overlay(alignment: .topTrailing) {
                            if unresolved {
                                Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 3, y: -3)
                            }
                        }
                }
            }
            .buttonStyle(.plain)
            .help(unresolved ? "当前键盘布局里找不到「\(entry.character ?? "")」，点击重新录制"
                  : entry.character == nil ? "点击录制快捷键" : "点击重新录制快捷键")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("从列表中移除")
        }
        .padding(.vertical, 3)
    }
}
