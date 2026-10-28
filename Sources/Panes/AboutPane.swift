import SwiftUI

struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("SwitchMux").font(.system(size: 20, weight: .semibold))
            Text("版本 \(AppInfo.shortVersion)（\(AppInfo.build)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("按住 Option（可在「高级」中修改）并按下数字键，快速切换、启动或隐藏应用。")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            UpdateSection()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
