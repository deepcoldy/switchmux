import AppKit
import ApplicationServices
import Combine

/// Owns the App Bar window: building slots, positioning, keyboard / mouse
/// handling, hover-to-switch and custom-mode drag reordering.
final class AppBarController {
    static let shared = AppBarController()

    private var panel: BarPanel?
    private var effectView: NSVisualEffectView?
    private var itemViews: [AppBarItemView] = []
    private(set) var slots: [Slot] = []
    private(set) var isVisible = false

    private var hideAfterTimer: Timer?
    private var pressedKey: String?
    private var hoveredKey: String?
    private var draggingKey: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Live-apply list / appearance edits while the bar is up.
        SettingsStore.shared.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isVisible, self.draggingKey == nil else { return }
                self.relayout()
            }
            .store(in: &cancellables)
    }

    // MARK: Screen selection
    private static func frontmostScreen() -> NSScreen? {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let windowRef = window, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        // AX uses top-left-origin global coordinates; convert to Cocoa's.
        guard let primary = NSScreen.screens.first else { return nil }
        let center = NSPoint(x: point.x + size.width / 2, y: primary.frame.maxY - (point.y + size.height / 2))
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        if SettingsStore.shared.showOnActiveScreen,
           let s = Self.frontmostScreen() ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return s
        }
        return NSScreen.main ?? screens[0]
    }

    // MARK: Show / hide
    func show() {
        show(on: targetScreen())
    }

    private func show(on screen: NSScreen) {
        guard !isVisible else { return }
        slots = AppsMonitor.shared.slots()
        guard !slots.isEmpty else { return }
        buildWindowIfNeeded()
        rebuildItems()
        positionPanel(on: screen)
        isVisible = true
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.fadeAlpha(to: 1, duration: 0.12)
        }
        scheduleHideAfter()
    }

    /// Settings "预览": show the bar briefly with the current appearance.
    func preview() {
        show()
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
    private var previewWork: DispatchWorkItem?

    /// Debug hook (SWITCHMUX_SMOKE): show the bar immediately.
    func smokeShow() {
        show(on: NSScreen.screens[0])
    }

    /// Debug hook: rasterize the bar to a PNG without screen-capture permission.
    func smokeDump(to path: String) {
        guard let view = panel?.contentView else { return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        var report = "bounds=\(view.bounds) slots=\(slots.count)\n"
        for (i, v) in itemViews.enumerated() {
            report += "item[\(i)] frame=\(v.frame) icon=\(v.subviews.first?.frame ?? .zero)\n"
        }
        try? report.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    func hide(activateHovered: Bool = false) {
        guard isVisible else { return }
        hideAfterTimer?.invalidate()
        if activateHovered, let key = hoveredKey,
           let slot = slots.first(where: { $0.key == key }),
           draggingKey == nil {
            trigger(slot)
        }
        isVisible = false
        hoveredKey = nil
        draggingKey = nil
        fadeAlpha(to: 0, duration: 0.1) { [weak self] in
            guard self?.isVisible == false else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private var fadeTimer: Timer?
    private func fadeAlpha(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let panel else { completion?(); return }
        let start = panel.alphaValue
        guard duration > 0, abs(start - target) > 0.001 else {
            panel.alphaValue = target
            completion?()
            return
        }
        let startDate = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let p = min(1, Date().timeIntervalSince(startDate) / duration)
            panel.alphaValue = start + (target - start) * CGFloat(p)
            if p >= 1 {
                t.invalidate()
                self?.fadeTimer = nil
                completion?()
            }
        }
    }

    private func scheduleHideAfter() {
        hideAfterTimer?.invalidate()
        let delay = SettingsStore.shared.hideAfter
        guard delay > 0 else { return }
        hideAfterTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hide(activateHovered: false)
        }
    }

    /// Called when running-app state changes; refreshes chrome while visible.
    func reloadIfVisible() {
        relayout()
    }

    private func relayout() {
        guard isVisible else { return }
        slots = AppsMonitor.shared.slots()
        if slots.isEmpty { hide(); return }
        rebuildItems(keepWindow: true)
        positionPanel(on: panel?.screen ?? targetScreen())
    }

    // MARK: Window construction
    private func buildWindowIfNeeded() {
        guard panel == nil else {
            configureEffect()
            return
        }
        let panel = BarPanel()
        let effect = NSVisualEffectView(frame: .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        panel.contentView = backdrop
        backdrop.addSubview(effect)
        self.panel = panel
        self.effectView = effect
        configureEffect()
    }

    private func configureEffect() {
        let m = BarMetrics.current
        effectView?.layer?.cornerRadius = m.barCorner
        effectView?.alphaValue = CGFloat(SettingsStore.shared.barOpacity)
        panel?.contentView?.layer?.cornerRadius = m.barCorner
        panel?.contentView?.layer?.cornerCurve = .continuous
        panel?.contentView?.layer?.masksToBounds = true
    }

    private func measuredSize(metrics m: BarMetrics) -> NSSize {
        let count = max(slots.count, 1)
        let width = m.barPaddingX * 2 + CGFloat(count) * m.tileWidth
            + CGFloat(max(0, count - 1)) * m.tileSpacing
        let height = m.barPaddingY * 2 + m.tileHeight
        return NSSize(width: width, height: height)
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel else { return }
        let m = BarMetrics.current
        let size = measuredSize(metrics: m)
        let vf = screen.visibleFrame
        let margin: CGFloat = 24

        var origin = NSPoint()
        switch SettingsStore.shared.horizontalPosition {
        case .left:   origin.x = vf.minX + margin
        case .center: origin.x = vf.midX - size.width / 2
        case .right:  origin.x = vf.maxX - size.width - margin
        }
        switch SettingsStore.shared.verticalPosition {
        case .top:    origin.y = vf.maxY - size.height - margin
        case .middle: origin.y = vf.midY - size.height / 2
        case .bottom: origin.y = vf.minY + margin
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        effectView?.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: Item views
    private func rebuildItems(keepWindow: Bool = false) {
        guard let effectView else { return }
        let m = BarMetrics.current
        configureEffect()

        var reused: [String: AppBarItemView] = [:]
        for v in itemViews { reused[v.slotKey] = v }

        for v in itemViews { v.removeFromSuperview() }
        itemViews.removeAll(keepingCapacity: true)

        var x = m.barPaddingX
        for slot in slots {
            let view: AppBarItemView
            if let existing = reused[slot.key] {
                view = existing
                view.configure(slot: slot, metrics: m)
            } else {
                view = makeItemView(slot: slot, metrics: m)
            }
            view.borderWidth = CGFloat(SettingsStore.shared.borderWidth)
            view.frame = NSRect(x: x, y: m.barPaddingY, width: m.tileWidth, height: m.tileHeight)
            effectView.addSubview(view)
            itemViews.append(view)
            x += m.tileWidth + m.tileSpacing
        }
    }

    private func makeItemView(slot: Slot, metrics m: BarMetrics) -> AppBarItemView {
        let view = AppBarItemView(slot: slot, metrics: m)
        view.borderWidth = CGFloat(SettingsStore.shared.borderWidth)
        view.onClick = { [weak self, weak view] in
            guard let self else { return }
            view?.isHovered = true
            self.hoveredKey = slot.key
            self.trigger(slot)
        }
        view.onHoverChanged = { [weak self, weak view] hovered in
            guard let self else { return }
            if hovered {
                self.itemViews.forEach { $0.isHovered = ($0 === view) }
                self.hoveredKey = slot.key
            } else if self.hoveredKey == slot.key {
                self.hoveredKey = nil
            }
        }
        view.onDragBegan = { [weak self] _ in self?.draggingKey = slot.key }
        view.onDragMoved = { [weak self] point in self?.handleDrag(to: point) }
        view.onDragEnded = { [weak self] in self?.draggingKey = nil }
        return view
    }

    // MARK: Keyboard
    /// A bound key was pressed while the activation modifier is held (the
    /// event tap already checked modifiers and silent rules). Works whether
    /// or not the bar is visible ("never display" = blind shortcuts).
    func triggerKey(_ keyCode: UInt16) {
        let current = isVisible ? slots : AppsMonitor.shared.slots()
        guard let slot = current.first(where: { $0.keyCode == keyCode }) else { return }
        if isVisible { flash(slotKey: slot.key) }
        trigger(slot)
    }

    private func flash(slotKey: String) {
        pressedKey = slotKey
        if let v = itemViews.first(where: { $0.slotKey == slotKey }) { v.isPressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard self?.pressedKey == slotKey else { return }
            self?.pressedKey = nil
            self?.itemViews.first { $0.slotKey == slotKey }?.isPressed = false
        }
    }

    private func trigger(_ slot: Slot) {
        AppActivator.trigger(slot, allowHide: SettingsStore.shared.hideOnRepeat)
        SettingsStore.shared.recordUsage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadIfVisible()
        }
    }

    // MARK: Drag to reorder
    private func handleDrag(to screenPoint: NSPoint) {
        guard let draggingKey else { return }
        var targetIndex: Int?
        for (idx, view) in itemViews.enumerated() where view.slotKey != draggingKey {
            guard let window = view.window else { continue }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            if rect.contains(screenPoint) { targetIndex = idx; break }
        }
        var apps = SettingsStore.shared.apps
        guard let targetIndex,
              let from = apps.firstIndex(where: { $0.id.uuidString == draggingKey }),
              targetIndex != from else { return }
        let entry = apps.remove(at: from)
        apps.insert(entry, at: min(targetIndex, apps.count))
        SettingsStore.shared.apps = apps
        relayout()
    }
}
