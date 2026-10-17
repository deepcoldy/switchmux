import AppKit

/// One icon tile in the App Bar: app icon, trigger-key badge, running dot,
/// active border and hover highlight.
final class AppBarItemView: NSView {
    let slotKey: String

    private let iconView = NSImageView()
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()

    private var tracking: NSTrackingArea?

    var isHovered = false { didSet { needsLayout = true; layer?.setNeedsLayout() } }
    var isPressed = false { didSet { needsLayout = true } }
    var isActive = false { didSet { needsLayout = true } }
    var isRunning = false { didSet { needsLayout = true } }
    var isHiddenApp = false { didSet { needsLayout = true } }
    var borderWidth: CGFloat = 3 { didSet { needsLayout = true } }

    // Mouse callbacks (window coordinates).
    var onClick: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var mouseDownPoint: NSPoint = .zero
    private var dragging = false

    init(slot: Slot, metrics: BarMetrics) {
        self.slotKey = slot.key
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = slot.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = nil
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = metrics.iconRadius
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        badgeView.wantsLayer = true
        badgeView.layer?.zPosition = 100
        badgeView.layer?.cornerRadius = metrics.badgeHeight / 2 - 1
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.backgroundColor = NSColor(white: 0.17, alpha: 0.88).cgColor
        badgeView.layer?.borderWidth = 0.5
        badgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(badgeView)

        badgeLabel.font = .systemFont(ofSize: metrics.badgeFontSize, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.backgroundColor = .clear
        badgeLabel.isBezeled = false
        badgeView.addSubview(badgeLabel)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = metrics.dotSize / 2
        addSubview(dotView)

        configure(slot: slot, metrics: metrics)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(slot: Slot, metrics: BarMetrics) {
        iconView.image = slot.icon
        badgeLabel.stringValue = slot.character?.uppercased() ?? ""
        badgeView.isHidden = (slot.character == nil)
        isActive = slot.active
        isRunning = slot.running
        isHiddenApp = slot.hidden
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = BarMetrics.current
        iconView.frame = NSRect(x: (bounds.width - m.iconSize) / 2,
                                y: m.dotGap + m.dotSize + m.iconBottomGap,
                                width: m.iconSize, height: m.iconSize)

        let badgeSize = badgeLabel.stringValue.count > 1 ? m.badgeWidthWide : m.badgeWidth
        badgeView.frame = NSRect(x: iconView.frame.minX - m.badgeOverlap,
                                 y: iconView.frame.minY - m.badgeOverlap,
                                 width: badgeSize, height: m.badgeHeight)
        badgeLabel.frame = NSRect(x: 0, y: (m.badgeHeight - m.badgeFontSize) / 2 - 1,
                                  width: badgeSize, height: m.badgeFontSize + 2)
        dotView.frame = NSRect(x: (bounds.width - m.dotSize) / 2, y: 0,
                               width: m.dotSize, height: m.dotSize)
        updateChrome()
    }

    private func updateChrome() {
        iconView.layer?.borderWidth = isActive ? borderWidth : 0
        iconView.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor

        let bg: NSColor
        if isPressed { bg = NSColor.white.withAlphaComponent(0.28) }
        else if isHovered { bg = NSColor.white.withAlphaComponent(0.16) }
        else { bg = .clear }
        layer?.backgroundColor = bg.cgColor
        layer?.cornerRadius = BarMetrics.current.tileCorner
        layer?.cornerCurve = .continuous

        iconView.alphaValue = isHiddenApp ? 0.45 : 1.0

        dotView.layer?.backgroundColor = isRunning
            ? NSColor.white.withAlphaComponent(0.85).cgColor
            : NSColor.white.withAlphaComponent(0.18).cgColor
    }

    // MARK: Hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?(false)
    }

    // MARK: Click / drag (reorder in Custom mode)
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation
        dragging = false
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging && hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 4 {
            dragging = true
            isPressed = false
            onDragBegan?(p)
        }
        if dragging { onDragMoved?(p) }
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if dragging {
            dragging = false
            onDragEnded?()
        } else {
            onClick?()
        }
    }
}
