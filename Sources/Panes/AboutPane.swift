import SwiftUI

struct AboutPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("SwitchMux").font(.system(size: 22, weight: .semibold))
            Text("版本 1.0.0（1）")
                .foregroundStyle(.secondary)
            Text("按住 Option（可在「高级」中修改）并按下数字键，快速切换、启动或隐藏应用。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Text("已累计使用 \(settings.usageCount) 次")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("原生 Swift / AppKit 应用与窗口快速切换器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
