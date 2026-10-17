import AppKit

/// Layout metrics for the App Bar, scaled by the user's size setting.
struct BarMetrics {
    let scale: CGFloat

    var iconSize: CGFloat { 60 * scale }
    var iconRadius: CGFloat { 14 * scale }
    var iconBottomGap: CGFloat { 10 * scale }
    var dotSize: CGFloat { 6 * scale }
    var dotGap: CGFloat { 6 * scale }

    var tileWidth: CGFloat { iconSize }
    var tileHeight: CGFloat { iconSize + iconBottomGap + dotSize + dotGap }
    var tileSpacing: CGFloat { 10 * scale }
    var tileCorner: CGFloat { 14 * scale }

    var barPaddingX: CGFloat { 12 * scale }
    var barPaddingY: CGFloat { 10 * scale }
    var barCorner: CGFloat { 18 * scale }

    var badgeHeight: CGFloat { 19 * scale }
    var badgeWidth: CGFloat { 22 * scale }
    var badgeWidthWide: CGFloat { 34 * scale }
    var badgeFontSize: CGFloat { 12 * scale }
    /// Key badge inset from the icon's lower-left corner.
    var badgeInset: CGFloat { 5 * scale }

    static var current: BarMetrics { BarMetrics(scale: CGFloat(SettingsStore.shared.barSizeScale)) }

    var contentSize: NSSize {
        // Placeholder; actual size is computed from slot count in the controller.
        .zero
    }
}
