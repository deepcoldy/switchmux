import SwiftUI

/// Compact updater controls embedded in the About pane (no toolbar slot of
/// its own — ten toolbar items overflow past the window width).
struct UpdateSection: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("自动更新").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $settings.autoUpdateCheck)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                HStack(spacing: 10) {
                    Button {
                        updater.checkNow(mode: .manual)
                    } label: {
                        Text("立即检查")
                    }
                    .disabled(updater.state.isBusy)
                    if case .checking = updater.state { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(lastCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusView
            }
            .padding(6)
        }
        .frame(maxWidth: 460)
    }

    @ViewBuilder private var statusView: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("正在检查更新…").font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                Label("发现新版本 \(release.title)", systemImage: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                releaseNotes(release.releaseNotes)
                HStack {
                    Button("立即下载") { updater.startDownload(release) }
                    Button("跳过此版本") { updater.skipCurrentVersion() }
                }
            }
        case .downloading(let release, let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("正在下载 \(release.title)").font(.caption)
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在校验安装包…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let pending):
            VStack(alignment: .leading, spacing: 6) {
                Label("版本 \(pending.version) 已准备好", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                releaseNotes(pending.releaseNotes)
                HStack {
                    Button {
                        updater.installPending()
                    } label: {
                        Label("重启并安装 \(pending.version)", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("跳过此版本") { updater.skipCurrentVersion() }
                }
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("在浏览器中打开下载页") { updater.openReleasesPage() }
            }
        }
    }

    private func releaseNotes(_ notes: String) -> some View {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                ScrollView {
                    Text(trimmed)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(height: 90)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return "从未检查" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "上次检查 \(f.string(from: date))"
    }
}
