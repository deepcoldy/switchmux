import SwiftUI

struct AppearancePane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("App Bar") {
                VStack(alignment: .leading) {
                    Text("大小：\(Int(settings.barSizeScale * 100))%")
                    Slider(value: $settings.barSizeScale, in: 0.7...1.4, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("不透明度：\(Int(settings.barOpacity * 100))%")
                    Slider(value: $settings.barOpacity, in: 0.3...1.0, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("高亮边框粗细：\(Int(settings.borderWidth)) px")
                    Slider(value: $settings.borderWidth, in: 0...6, step: 1)
                }
            }
            Section("位置") {
                Picker("垂直位置", selection: $settings.verticalPosition) {
                    ForEach(BarVerticalPosition.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("水平位置", selection: $settings.horizontalPosition) {
                    ForEach(BarHorizontalPosition.allCases, id: \.self) { h in
                        Text(h.label).tag(h)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Button("恢复默认外观") {
                    settings.barSizeScale = 1.0
                    settings.barOpacity = 0.95
                    settings.borderWidth = 3
                    settings.verticalPosition = .middle
                    settings.horizontalPosition = .center
                }
            }
        }
        .formStyle(.grouped)
    }
}
