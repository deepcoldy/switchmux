import AppKit

/// Owns the window thumbnail overlay: window snapshot, grid layout,
/// keyboard navigation (Tab / arrows / digits / Q W H M / Esc), hover select,
/// and activate-on-release.
final class WindowSwitcherController {
    static let shared = WindowSwitcherController()

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var cardViews: [WindowCardView] = []
    private(set) var items: [WindowItem] = []
    private(set) var isVisible = false

    private(set) var selection = 0
    private(set) var columns = 1
    var itemsCount: Int { items.count }
    private var navigated = false
    private var cancelled = false
    private var fadeTimer: Timer?

    private init() {}

    // MARK: Show / hide
    func show() {
        guard !isVisible else { return }
        let s = SettingsStore.shared
        items = WindowStore.snapshot(scope: s.windowScope,
                                     includeMinimized: s.includeMinimizedWindows,
                                     includeHidden: s.includeHiddenAppWindows)
        guard !items.isEmpty else { return }
        if !ScreenCapturePermission.status { ScreenCapturePermission.request() }
        buildPanelIfNeeded()
        rebuild()
        isVisible = true
        selection = 0
        navigated = false
        cancelled = false
        updateSelection()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.fade(to: 1, duration: 0.12) }
    }

    func finish(activate: Bool) {
        guard isVisible else { return }
        isVisible = false
        if activate && navigated && items.indices.contains(selection) {
            WindowActions.activate(items[selection])
        }
        fade(to: 0, duration: 0.1) { [weak self] in self?.panel?.orderOut(nil) }
    }

    func cancel() {
        cancelled = true
        finish(activate: false)
    }

    // MARK: Keyboard
    /// Returns true when the event was swallowed.
    func handleKey(_ event: NSEvent) -> Bool {
        // Before the overlay exists, only the trigger key (Tab) arms it —
        // this keeps ordinary modifier shortcuts untouched.
        if !isVisible {
            if event.keyCode == 48 {
                show()
                if isVisible { move(forward: !event.modifierFlags.contains(.shift)) }
                return true
            }
            return false
        }
        switch event.keyCode {
        case 48: // Tab
            move(forward: !event.modifierFlags.contains(.shift))
            return true
        case 53: // Esc
            cancel()
            return true
        case 36, 76: // Return / Enter
            navigated = true
            finish(activate: true)
            return true
        case 123: move(forward: false); return true  // left
        case 124: move(forward: true); return true   // right
        case 125: move(vertical: 1); return true     // down
        case 126: move(vertical: -1); return true    // up
        case 12: // Q
            actionOnSelection { WindowActions.quitApp($0) }; return true
        case 13: // W
            actionOnSelection { WindowActions.closeWindow($0) }; return true
        case 4:  // H
            actionOnSelection { WindowActions.hideApp($0) }; return true
        case 46: // M
            actionOnSelection { WindowActions.minimizeWindow($0) }; return true
        default:
            break
        }
        // Digits 1-9 select directly (0 = 10).
        if let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 0, n <= 9 {
            let idx = n == 0 ? 9 : n - 1
            if items.indices.contains(idx) {
                selection = idx
                navigated = true
                updateSelection()
            }
            return true
        }
        return false
    }

    private func move(forward: Bool) {
        guard !items.isEmpty else { return }
        selection = (selection + (forward ? 1 : -1) + items.count) % items.count
        navigated = true
        updateSelection()
    }

    private func move(vertical: Int) {
        guard !items.isEmpty, columns > 0 else { return }
        let target = selection + vertical * columns
        if items.indices.contains(target) { selection = target }
        navigated = true
        updateSelection()
    }

    private func actionOnSelection(_ action: (WindowItem) -> Void) {
        guard items.indices.contains(selection) else { return }
        let target = items[selection]
        action(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshAfterAction(except: target.windowID)
        }
    }

    private func refreshAfterAction(except removedID: CGWindowID) {
        guard isVisible else { return }
        let s = SettingsStore.shared
        items = WindowStore.snapshot(scope: s.windowScope,
                                     includeMinimized: s.includeMinimizedWindows,
                                     includeHidden: s.includeHiddenAppWindows)
            .filter { $0.windowID != removedID }
        if items.isEmpty { cancel(); return }
        selection = min(selection, items.count - 1)
        rebuild()
        updateSelection()
    }

    private func updateSelection() {
        for (i, view) in cardViews.enumerated() {
            view.isSelected = i == selection
        }
    }

    // MARK: Window / layout
    private func buildPanelIfNeeded() {
        if panel != nil { return }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 10)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .default
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let backdrop = NSView()
        backdrop.wantsLayer = true
        panel.contentView = backdrop
        let effect = NSVisualEffectView(frame: .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        backdrop.addSubview(effect)
        effectView = effect
        self.panel = panel
    }

    private func rebuild() {
        guard let effectView else { return }
        for v in cardViews { v.removeFromSuperview() }
        cardViews.removeAll(keepingCapacity: true)

        let m = SwitcherMetrics.current
        effectView.layer?.cornerRadius = m.corner
        let screen = targetScreen()
        let maxWidth = screen.visibleFrame.width * 0.94
        columns = max(1, Int((maxWidth - m.paddingX * 2 + m.gap) / (m.cardWidth + m.gap)))
        columns = min(columns, max(1, items.count))
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let width = m.paddingX * 2 + CGFloat(columns) * m.cardWidth + CGFloat(columns - 1) * m.gap
        let height = m.paddingY * 2 + CGFloat(rows) * m.cardHeight + CGFloat(max(0, rows - 1)) * m.gap
        let size = NSSize(width: width, height: height)

        for (i, item) in items.enumerated() {
            let key = i < 9 ? String(i + 1) : (i == 9 ? "0" : nil)
            let card = WindowCardView(item: item, key: key, metrics: m)
            let row = i / columns
            let col = i % columns
            card.frame = NSRect(
                x: m.paddingX + CGFloat(col) * (m.cardWidth + m.gap),
                y: m.paddingY + CGFloat(rows - 1 - row) * (m.cardHeight + m.gap),
                width: m.cardWidth, height: m.cardHeight)
            card.onHoverChanged = { [weak self] hovered in
                guard hovered else { return }
                self?.selection = i
                self?.navigated = true
                self?.updateSelection()
            }
            card.onClick = { [weak self] in
                self?.selection = i
                self?.navigated = true
                self?.finish(activate: true)
            }
            effectView.addSubview(card)
            cardViews.append(card)
        }

        panel?.setFrame(NSRect(origin: .zero, size: size), display: false)
        effectView.frame = NSRect(origin: .zero, size: size)
        position(on: screen, size: size)

        requestThumbnails()
    }

    /// Batch-capture via the privileged helper. It is a fresh process, so it
    /// sees grants made after SwitchMux launched — no restart needed.
    private func requestThumbnails() {
        guard WindowCapture.isAvailable else { return }
        let targets = items
        WindowCapture.capture(targets) { [weak self] images in
            guard let self, self.isVisible else { return }
            for card in self.cardViews {
                if let img = images[card.windowID] { card.setThumbnail(img) }
            }
        }
    }

    private func targetScreen() -> NSScreen {
        if SettingsStore.shared.showOnActiveScreen,
           let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func position(on screen: NSScreen, size: NSSize) {
        let vf = screen.visibleFrame
        panel?.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                     y: vf.midY - size.height / 2))
    }

    private func fade(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let panel else { completion?(); return }
        let start = panel.alphaValue
        let startDate = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let p = min(1, Date().timeIntervalSince(startDate) / duration)
            panel.alphaValue = start + (target - start) * CGFloat(p)
            if p >= 1 {
                t.invalidate(); self?.fadeTimer = nil; completion?()
            }
        }
    }

    /// Debug hook: rasterize the switcher overlay to PNG.
    func smokeDump(to path: String) {
        guard let view = panel?.contentView else { return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Debug hook: select an arbitrary card (verifies chrome).
    func smokeSelect(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        updateSelection()
    }
}
