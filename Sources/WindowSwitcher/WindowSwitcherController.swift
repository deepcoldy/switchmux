import AppKit

/// Window switcher sessions (⌘Tab for all windows, ⌥` for the current app).
///
/// A session starts on the trigger hotkey and ends when the modifier is
/// released. The window list is built on a background queue; the overlay only
/// appears if the modifier is still held after a short delay, so a quick
/// ⌘Tab-and-release switches straight to the previous window without any UI
/// flash — like the native switcher and alt-tab.
final class WindowSwitcherController {
    static let shared = WindowSwitcherController()

    /// Called when the session ends from the UI side (Esc, Return, click), so
    /// the hotkey layer stops routing keys here.
    var onSessionEnded: (() -> Void)?

    private final class Session {
        let id: Int
        let scope: WindowScope
        var frontPID: pid_t?
        var items: [WindowItem]?
        var steps: Int
        /// Released before its window list arrived: activate as soon as it does.
        var finishing = false
        var showRequested = false
        /// List derived from the previous session's target (which is item 0).
        var anchored = false

        init(id: Int, scope: WindowScope, frontPID: pid_t?, steps: Int) {
            self.id = id; self.scope = scope; self.frontPID = frontPID; self.steps = steps
        }
    }

    /// Finishing sessions in order, optionally followed by the live one.
    /// Rapid ⌘Tab ⌘Tab presses can outrun the window enumeration; each press is
    /// its own session and later ones derive their list from the window the
    /// earlier one activated, so back-and-forth toggling lands correctly.
    private var queue: [Session] = []
    private var sessionCounter = 0
    private var refreshCounter = 0
    private var showWork: DispatchWorkItem?
    private let showDelay: TimeInterval = 0.12

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var cardViews: [WindowCardView] = []
    private(set) var isVisible = false
    private(set) var selection = 0
    private var columns = 1
    private var mouseAtShow: NSPoint = .zero
    private var fadeTimer: Timer?

    private var live: Session? {
        guard let last = queue.last, !last.finishing else { return nil }
        return last
    }
    var isSessionActive: Bool { live != nil }
    var itemsCount: Int { live?.items?.count ?? 0 }
    private var items: [WindowItem] { live?.items ?? [] }

    private init() {}

    // MARK: Session lifecycle
    func beginSession(scope: WindowScope, forward: Bool) {
        if live != nil { step(forward: forward); return }
        sessionCounter += 1
        let query = WindowStore.query(scope: scope)
        let session = Session(id: sessionCounter, scope: scope, frontPID: query.frontPID,
                              steps: forward ? 1 : -1)
        queue.append(session)
        if queue.count == 1 { fetch(session, query: query) }
        // else: it derives its list when the session ahead of it resolves.

        let id = session.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, let live = self.live, live.id == id else { return }
            live.showRequested = true
            if live.items != nil { self.present() }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private func fetch(_ session: Session, query: WindowStore.Query) {
        let id = session.id
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let list = WindowStore.snapshot(query)
            DispatchQueue.main.async {
                guard let self, let s = self.queue.first(where: { $0.id == id }), s.items == nil else { return }
                self.resolve(s, list)
            }
        }
    }

    /// Item 0 is normally the window you're on, so one step lands on the
    /// previous window. If the front app's first window isn't the visible one
    /// (no window, minimized, other Space), start before 0.
    private func baseIndex(_ list: [WindowItem], frontPID: pid_t?, anchored: Bool) -> Int {
        if anchored { return 0 }
        guard let first = list.first, first.pid == frontPID,
              first.isOnScreen, !first.isMinimized else { return -1 }
        return 0
    }

    private func resolve(_ session: Session, _ list: [WindowItem]) {
        session.items = list
        let index = list.isEmpty ? 0 : wrap(baseIndex(list, frontPID: session.frontPID, anchored: session.anchored) + session.steps, count: list.count)
        guard session.finishing else {
            selection = index
            if session.showRequested { present() }
            return
        }
        let target = list.isEmpty ? nil : list[index]
        if let target { activate(target) }
        queue.removeAll { $0 === session }
        guard let next = queue.first else { return }
        // The next session starts from where this one left focus.
        if let target, next.scope == session.scope {
            next.frontPID = target.pid
            next.anchored = true
            resolve(next, [target] + list.filter { $0.windowID != target.windowID })
        } else {
            var q = WindowStore.query(scope: next.scope)
            if let target { q.frontPID = target.pid }
            next.frontPID = q.frontPID
            fetch(next, query: q)
        }
    }

    func step(forward: Bool) {
        guard let s = live else { return }
        if s.items == nil {
            s.steps += forward ? 1 : -1
        } else {
            move(by: forward ? 1 : -1)
        }
    }

    /// Modifier released (activate = true) or session aborted.
    func endSession(activate: Bool) {
        guard let s = live else { return }
        guard activate else { drop(s); return }
        if s.items == nil {
            s.finishing = true      // resolves when its list arrives
            showWork?.cancel()
            hidePanel()
            return
        }
        complete(s)
    }

    func cancel() {
        guard let s = live else { return }
        drop(s)
        onSessionEnded?()
    }

    private func complete(_ s: Session) {
        if let list = s.items, list.indices.contains(selection) { activate(list[selection]) }
        drop(s)
    }

    private func drop(_ s: Session) {
        queue.removeAll { $0 === s }
        showWork?.cancel()
        showWork = nil
        hidePanel()
    }

    private func activate(_ item: WindowItem) {
        WindowActions.activate(item)
        SettingsStore.shared.recordUsage()
    }

    private func wrap(_ i: Int, count: Int) -> Int {
        ((i % count) + count) % count
    }

    // MARK: Keyboard (routed by the hotkey layer while a session is open)
    func handleKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let s = live else { return }
        switch keyCode {
        case KeyCodes.escape:
            cancel()
        case KeyCodes.returnKey, KeyCodes.enter:
            endSession(activate: true)
            onSessionEnded?()
        case KeyCodes.tab, KeyCodes.grave, KeyCodes.isoSection:
            step(forward: !flags.contains(.shift))
        case KeyCodes.left: step(forward: false)
        case KeyCodes.right: step(forward: true)
        case KeyCodes.down: move(vertical: 1)
        case KeyCodes.up: move(vertical: -1)
        case 12: actionOnSelection(s, WindowActions.quitApp, removes: .app)        // Q
        case 13: actionOnSelection(s, WindowActions.closeWindow, removes: .window) // W
        case 4:  actionOnSelection(s, WindowActions.hideApp, removes: .none)       // H
        case 46: actionOnSelection(s, WindowActions.minimizeWindow, removes: .none) // M
        default:
            if let ch = KeyCodes.character(for: keyCode), let n = Int(ch) {
                let idx = n == 0 ? 9 : n - 1
                if items.indices.contains(idx) {
                    selection = idx
                    updateSelection()
                }
            }
        }
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = wrap(selection + delta, count: items.count)
        updateSelection()
    }

    private func move(vertical: Int) {
        guard !items.isEmpty, columns > 0 else { return }
        let target = selection + vertical * columns
        if items.indices.contains(target) { selection = target }
        updateSelection()
    }

    private enum Removal { case none, window, app }

    private func actionOnSelection(_ s: Session, _ action: @escaping (WindowItem) -> Void, removes: Removal) {
        guard let list = s.items, list.indices.contains(selection) else { return }
        let target = list[selection]
        action(target)
        // Drop it right away (quit / close can take a while, e.g. save
        // prompts), then re-enumerate a few times to pick up the real state.
        switch removes {
        case .none: break
        case .window: apply(list.filter { $0.windowID != target.windowID }, to: s)
        case .app: apply(list.filter { $0.pid != target.pid }, to: s)
        }
        refreshCounter += 1
        let token = refreshCounter
        let query = WindowStore.query(scope: s.scope)
        for delay in [0.25, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                DispatchQueue.global(qos: .userInteractive).async {
                    var fresh = WindowStore.snapshot(query)
                    if removes == .app { fresh.removeAll { $0.pid == target.pid } }
                    DispatchQueue.main.async {
                        guard let self, self.refreshCounter == token, self.live === s else { return }
                        self.apply(fresh, to: s)
                    }
                }
            }
        }
    }

    private func apply(_ fresh: [WindowItem], to s: Session) {
        guard live === s else { return }
        s.items = fresh
        if fresh.isEmpty { cancel(); return }
        selection = min(selection, fresh.count - 1)
        if isVisible { rebuild() }
        updateSelection()
    }

    // MARK: Panel
    private func present() {
        guard !items.isEmpty else { return }
        buildPanelIfNeeded()
        rebuild()
        updateSelection()
        mouseAtShow = NSEvent.mouseLocation
        if !isVisible {
            isVisible = true
            panel?.alphaValue = 0
            panel?.orderFrontRegardless()
            fade(to: 1, duration: 0.1)
        }
    }

    private func hidePanel() {
        guard isVisible else { return }
        isVisible = false
        fade(to: 0, duration: 0.08) { [weak self] in
            guard self?.isVisible == false else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func updateSelection() {
        for (i, view) in cardViews.enumerated() { view.isSelected = i == selection }
    }

    private func buildPanelIfNeeded() {
        if panel != nil { return }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let backdrop = NSView()
        backdrop.wantsLayer = true
        panel.contentView = backdrop
        let effect = NSVisualEffectView(frame: .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
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

        let screen = targetScreen()
        let maxWidth = screen.visibleFrame.width * 0.94
        let maxHeight = screen.visibleFrame.height * 0.94
        // Shrink cards until every row fits on screen (many windows).
        var m = SwitcherMetrics.current
        var rows = 1
        var width: CGFloat = 0, height: CGFloat = 0
        while true {
            columns = max(1, Int((maxWidth - m.paddingX * 2 + m.gap) / (m.cardWidth + m.gap)))
            columns = min(columns, max(1, items.count))
            rows = Int(ceil(Double(items.count) / Double(columns)))
            width = m.paddingX * 2 + CGFloat(columns) * m.cardWidth + CGFloat(columns - 1) * m.gap
            height = m.paddingY * 2 + CGFloat(rows) * m.cardHeight + CGFloat(max(0, rows - 1)) * m.gap
            if height <= maxHeight || m.scale <= 0.35 { break }
            m = SwitcherMetrics(scale: m.scale * 0.9)
        }
        effectView.layer?.cornerRadius = m.corner
        let size = NSSize(width: width, height: min(height, maxHeight))

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
                guard let self, hovered else { return }
                // A card that merely ends up under a resting cursor must not
                // steal the selection; only real mouse movement counts.
                let p = NSEvent.mouseLocation
                guard hypot(p.x - self.mouseAtShow.x, p.y - self.mouseAtShow.y) > 2 else { return }
                self.selection = i
                self.updateSelection()
            }
            card.onClick = { [weak self] in
                guard let self else { return }
                self.selection = i
                if let s = self.live { self.complete(s) }
                self.onSessionEnded?()
            }
            effectView.addSubview(card)
            cardViews.append(card)
        }

        panel?.setFrame(NSRect(origin: .zero, size: size), display: false)
        effectView.frame = NSRect(origin: .zero, size: size)
        let vf = screen.visibleFrame
        panel?.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        requestThumbnails()
    }

    /// Batch-capture via the bundled helper. It is a fresh process, so it
    /// sees Screen Recording grants made after SwitchMux launched.
    private func requestThumbnails() {
        guard WindowCapture.isAvailable, let id = live?.id else { return }
        WindowCapture.capture(items) { [weak self] images in
            guard let self, self.live?.id == id else { return }
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
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func fade(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        guard let panel else { completion?(); return }
        let start = panel.alphaValue
        let startDate = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let p = min(1, Date().timeIntervalSince(startDate) / duration)
            panel.alphaValue = start + (target - start) * CGFloat(p)
            if p >= 1 {
                t.invalidate(); self?.fadeTimer = nil; completion?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Debug hooks
    /// Shows the overlay immediately for a screenshot (no hotkey session).
    func smokeShow() {
        beginSession(scope: SettingsStore.shared.windowScope, forward: true)
        live?.showRequested = true
    }

    func smokeDump(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
