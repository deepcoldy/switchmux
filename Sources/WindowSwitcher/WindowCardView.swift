import AppKit

/// One window thumbnail card in the switcher overlay.
final class WindowCardView: NSView {
    let windowID: CGWindowID

    private let thumbnailView = NSImageView()
    private let fallbackIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let stateBadge = NSTextField(labelWithString: "")
    private let badgeView = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    var isSelected = false { didSet { updateChrome() } }

    private let metrics: SwitcherMetrics
    private var thumbnailWork: DispatchWorkItem?

    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    init(item: WindowItem, key: String?, metrics: SwitcherMetrics) {
        self.windowID = item.windowID
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        thumbnailView.imageScaling = .scaleAxesIndependently
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 10
        thumbnailView.layer?.cornerCurve = .continuous
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        thumbnailView.isHidden = true
        addSubview(thumbnailView)

        fallbackIcon.image = item.icon
        fallbackIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(fallbackIcon)

        appIcon.image = item.icon
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(appIcon)

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        stateBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        stateBadge.textColor = NSColor.white.withAlphaComponent(0.7)
        addSubview(stateBadge)

        badgeView.wantsLayer = true
        badgeView.layer?.zPosition = 100
        badgeView.layer?.cornerRadius = metrics.badgeHeight / 2 - 1
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.backgroundColor = NSColor(white: 0.17, alpha: 0.88).cgColor
        badgeView.layer?.borderWidth = 0.5
        badgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(badgeView)

        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.backgroundColor = .clear
        badgeLabel.isBezeled = false
        badgeLabel.stringValue = key?.uppercased() ?? ""
        badgeView.isHidden = key == nil
        badgeView.addSubview(badgeLabel)

        configure(item: item, key: key)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: WindowItem, key: String?) {
        titleLabel.stringValue = item.title
        appIcon.image = item.icon
        fallbackIcon.image = item.icon
        badgeLabel.stringValue = key?.uppercased() ?? ""
        badgeView.isHidden = key == nil
        stateBadge.stringValue = item.isMinimized ? "—" : (item.isOnScreen ? "" : "◷")
        needsLayout = true
    }

    /// Assign a captured thumbnail (called in batches by the controller).
    func setThumbnail(_ image: NSImage) {
        thumbnailView.image = image
        thumbnailView.isHidden = false
        fallbackIcon.isHidden = true
    }

    override func layout() {
        super.layout()
        let m = metrics
        let imageH = m.cardHeight - m.footerHeight
        thumbnailView.frame = NSRect(x: 0, y: m.footerHeight, width: m.cardWidth, height: imageH)
        fallbackIcon.frame = thumbnailView.frame.insetBy(dx: m.cardWidth * 0.28, dy: imageH * 0.2)

        appIcon.frame = NSRect(x: 8, y: 6, width: 18, height: 18)
        titleLabel.frame = NSRect(x: 32, y: 7, width: m.cardWidth - 58, height: 16)
        stateBadge.frame = NSRect(x: m.cardWidth - 26, y: 6, width: 20, height: 16)

        let bw: CGFloat = badgeLabel.stringValue.count > 1 ? 30 : 22
        badgeView.frame = NSRect(x: 8, y: m.cardHeight - m.badgeHeight - 8, width: bw, height: m.badgeHeight)
        badgeLabel.frame = NSRect(x: 0, y: (m.badgeHeight - 14) / 2 - 1, width: bw, height: 15)
        updateChrome()
    }

    private func updateChrome() {
        layer?.borderWidth = isSelected ? 3 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.white.withAlphaComponent(0.04).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isSelected = true
        onHoverChanged?(true)
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}
