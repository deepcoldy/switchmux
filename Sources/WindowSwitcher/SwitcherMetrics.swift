import AppKit

struct SwitcherMetrics {
    let scale: CGFloat
    var cardWidth: CGFloat { 228 * scale }
    var cardHeight: CGFloat { 168 * scale }
    var footerHeight: CGFloat { 32 * scale }
    var gap: CGFloat { 12 * scale }
    var paddingX: CGFloat { 14 * scale }
    var paddingY: CGFloat { 14 * scale }
    var corner: CGFloat { 18 * scale }
    var badgeHeight: CGFloat { 19 * scale }

    static var current: SwitcherMetrics {
        SwitcherMetrics(scale: CGFloat(SettingsStore.shared.windowSwitcherScale))
    }
}
