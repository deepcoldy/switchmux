// SwitchMux promo video renderer.
//
// Draws every frame with AppKit / CoreGraphics and encodes H.264 with
// AVAssetWriter (1920x1080, 30 fps, silent). No ffmpeg needed.
//
//   swift scripts/promo/render.swift docs/media/switchmux-promo.mp4 [docs/media/promo-poster.png]
//   swift scripts/promo/render.swift --still <seconds> <out.png>     (preview one frame)
//
// Faster: swiftc -O scripts/promo/render.swift -o /tmp/promo-render && /tmp/promo-render <out.mp4>
//
// Assets: scripts/promo/assets (2x light-mode captures) and the built app icon; all
// window content is drawn demo content, never real user data.

import AppKit
import AVFoundation
import CoreVideo

// MARK: - Constants

let W = 1920, H = 1080, FPS = 30
let WF = CGFloat(W), HF = CGFloat(H)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let ivory = hex(0xFAF9F5)
let ivory2 = hex(0xF0EEE6)
let ink = hex(0x141413)
let ink2 = hex(0x5E5D59)
let gray = hex(0xB0AEA5)
let line = hex(0xE8E6DC)
let clay = hex(0xD97757)

// Repo root: <root>/scripts/promo/render.swift
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func repo(_ p: String) -> String { root.appendingPathComponent(p).path }

// MARK: - Fonts

/// New York serif for Latin, cascading to Songti SC for CJK glyphs.
func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)
        ?? NSFont.systemFont(ofSize: size).fontDescriptor
    let songName = weight >= .semibold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
    let song = NSFontDescriptor(name: songName, size: size)
    return NSFont(descriptor: base.addingAttributes([.cascadeList: [song]]), size: size)
        ?? NSFont.systemFont(ofSize: size)
}

/// PingFang SC for body copy.
func sans(_ size: CGFloat, _ style: String = "Regular") -> NSFont {
    NSFont(name: "PingFangSC-\(style)", size: size) ?? NSFont.systemFont(ofSize: size)
}

func system(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

// MARK: - Easing / timing

func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
func easeInOut(_ x: Double) -> Double {
    let x = clamp01(x)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
/// Eased progress of an animation starting at `start` lasting `dur` seconds.
func prog(_ t: Double, _ start: Double, _ dur: Double = 0.7) -> Double {
    easeInOut((t - start) / dur)
}
func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
func mixRect(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, p), y: mix(a.minY, b.minY, p),
           width: mix(a.width, b.width, p), height: mix(a.height, b.height, p))
}
func mixColor(_ a: NSColor, _ b: NSColor, _ p: Double) -> NSColor {
    a.blended(withFraction: CGFloat(clamp01(p)), of: b) ?? a
}

// MARK: - Drawing context helpers

var ctx: CGContext!

func group(alpha: Double, dx: CGFloat = 0, dy: CGFloat = 0, _ body: () -> Void) {
    guard alpha > 0.002 else { return }
    ctx.saveGState()
    ctx.translateBy(x: dx, y: dy)
    if alpha < 0.998 {
        ctx.setAlpha(CGFloat(alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
    } else {
        body()
    }
    ctx.restoreGState()
}

/// Fade + gentle upward drift, starting at `start`.
func reveal(_ t: Double, _ start: Double, dur: Double = 0.7, rise: CGFloat = 18, _ body: () -> Void) {
    let p = prog(t, start, dur)
    group(alpha: p, dy: rise * CGFloat(1 - p), body)
}

/// Scale the drawing around a point.
func scaled(_ s: CGFloat, around c: CGPoint, _ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -c.x, y: -c.y)
    body()
    ctx.restoreGState()
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    // Shadow offsets live in device space (y up), so "down" is negative.
    ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur,
                  color: NSColor(white: 0, alpha: alpha).cgColor)
}

func rr(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func fill(_ path: NSBezierPath, _ c: NSColor) { c.setFill(); path.fill() }

/// Rounded panel with a soft layered shadow.
func softPanel(_ r: CGRect, radius: CGFloat, color: NSColor, strength: CGFloat = 1) {
    ctx.saveGState(); shadow(60, 24, 0.10 * strength); fill(rr(r, radius), color); ctx.restoreGState()
    ctx.saveGState(); shadow(6, 2, 0.06 * strength); fill(rr(r, radius), color); ctx.restoreGState()
}

func drawImage(_ img: NSImage, in r: CGRect, alpha: CGFloat = 1, radius: CGFloat = 0) {
    NSGraphicsContext.saveGraphicsState()
    if radius > 0 { rr(r, radius).addClip() }
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true,
             hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
}

/// Offscreen flipped bitmap, `scale` pixels per point.
func bitmap(_ size: CGSize, scale: CGFloat = 2, _ draw: () -> Void) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let saved = ctx
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let c = g.cgContext
    // The rep's size already maps points to pixels; only flip.
    c.translateBy(x: 0, y: size.height)
    c.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: c, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = flipped
    ctx = c
    draw()
    NSGraphicsContext.restoreGraphicsState()
    ctx = saved
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    return img
}

// MARK: - Text

func attr(_ s: String, _ f: NSFont, _ c: NSColor, kern: CGFloat = 0, lineHeight: CGFloat? = nil,
          align: NSTextAlignment = .left) -> NSAttributedString {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    if let lh = lineHeight { ps.minimumLineHeight = lh; ps.maximumLineHeight = lh }
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern,
                                                      .paragraphStyle: ps])
}

@discardableResult
func text(_ a: NSAttributedString, x: CGFloat, y: CGFloat) -> CGSize {
    let size = a.size()
    a.draw(at: CGPoint(x: x, y: y))
    return size
}

@discardableResult
func textCentered(_ a: NSAttributedString, cx: CGFloat, y: CGFloat) -> CGSize {
    let size = a.size()
    a.draw(at: CGPoint(x: cx - size.width / 2, y: y))
    return size
}

func textCenteredIn(_ a: NSAttributedString, _ r: CGRect) {
    let size = a.size()
    a.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
}

// MARK: - Assets

func appIcon(_ path: String) -> NSImage {
    let img = NSWorkspace.shared.icon(forFile: path)
    img.size = NSSize(width: 256, height: 256)
    return img
}

let switchMuxIcon: NSImage = {
    for p in [repo("build/SwitchMux.app/Contents/Resources/AppIcon.icns"),
              repo("docs/screenshots/app-icon.svg")] {
        if let img = NSImage(contentsOfFile: p) { return img }
    }
    fatalError("SwitchMux app icon not found (build the app first)")
}()

/// 2x light-mode product captures in scripts/promo/assets (made with the app's
/// SWITCHMUX_SMOKE_PANES / SWITCHMUX_SMOKE_GUIDE hooks rendered into a 2x
/// bitmap, demo config). Point size = pixels / 2, so they are only ever
/// downscaled into the frame.
func asset(_ name: String) -> NSImage {
    guard let img = NSImage(contentsOfFile: scriptURL.deletingLastPathComponent()
        .appendingPathComponent("assets/\(name)").path) else {
        fatalError("missing promo asset \(name)")
    }
    if let rep = img.representations.first {
        img.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
    }
    return img
}

/// Bounding box of the opaque pixels, in points (captures may carry transparent margins).
func opaqueBounds(_ img: NSImage) -> CGRect {
    guard let data = img.tiffRepresentation, let rep = NSBitmapImageRep(data: data) else {
        return CGRect(origin: .zero, size: img.size)
    }
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let k = CGFloat(rep.pixelsWide) / img.size.width
    return CGRect(x: CGFloat(minX) / k, y: CGFloat(minY) / k,
                  width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
}

struct DemoApp { let name: String; let path: String; let key: String }

let barApps: [DemoApp] = [
    .init(name: "Finder", path: "/System/Library/CoreServices/Finder.app", key: "1"),
    .init(name: "Safari", path: "/Applications/Safari.app", key: "2"),
    .init(name: "Mail", path: "/System/Applications/Mail.app", key: "3"),
    .init(name: "Notes", path: "/System/Applications/Notes.app", key: "4"),
    .init(name: "Calendar", path: "/System/Applications/Calendar.app", key: "5"),
    .init(name: "Music", path: "/System/Applications/Music.app", key: "6"),
    .init(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", key: "T"),
    .init(name: "Messages", path: "/System/Applications/Messages.app", key: "M"),
    .init(name: "System Settings", path: "/System/Applications/System Settings.app", key: "S"),
]
let barIcons = barApps.map { appIcon($0.path) }

struct DemoWindow {
    let appPath: String; let title: String; let accent: NSColor; let dark: Bool
    var url: String? = nil
}

var iconCache: [String: NSImage] = [:]
func icon(_ path: String) -> NSImage {
    if let i = iconCache[path] { return i }
    let i = appIcon(path); iconCache[path] = i; return i
}

/// Drawn window mock (same look as the app's SWITCHMUX_DEMO thumbnails), with
/// a real title bar: app icon + window title, and a URL pill for browsers.
func windowMock(_ w: DemoWindow) -> NSImage {
    let size = CGSize(width: 480, height: 300)
    let dark = w.dark, accent = w.accent
    return bitmap(size, scale: 2.5) {
        let rect = CGRect(origin: .zero, size: size)
        let bg = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        let fg = dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.09)
        let chrome = dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        let titleInk = dark ? NSColor(white: 1, alpha: 0.82) : NSColor(white: 0, alpha: 0.72)
        bg.setFill(); rect.fill()
        let barH: CGFloat = w.url == nil ? 30 : 58
        chrome.setFill()
        CGRect(x: 0, y: 0, width: rect.width, height: barH).fill()
        (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10)).setFill()
        CGRect(x: 0, y: barH - 0.5, width: rect.width, height: 0.5).fill()
        for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: 44 + CGFloat(j) * 18, y: 10, width: 11, height: 11)).fill()
        }
        // Icon + title, centred in the title row.
        let title = attr(w.title, sans(12, "Medium"), titleInk)
        let ts = title.size()
        let groupW = 16 + 6 + ts.width
        let gx = rect.midX - groupW / 2
        drawImage(icon(w.appPath), in: CGRect(x: gx, y: 7, width: 16, height: 16))
        title.draw(at: CGPoint(x: gx + 22, y: 15 - ts.height / 2))
        if let url = w.url {
            let pill = CGRect(x: rect.midX - 130, y: 31, width: 260, height: 21)
            fill(rr(pill, 6), dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.95))
            let u = attr(url, sans(10.5), titleInk)
            let us = u.size()
            // Lock glyph drawn as a tiny padlock.
            let lx = pill.midX - (us.width + 12) / 2
            fill(rr(CGRect(x: lx, y: pill.midY - 1, width: 7, height: 6), 1.2), titleInk.withAlphaComponent(0.55))
            let shackle = NSBezierPath(roundedRect: CGRect(x: lx + 1.4, y: pill.midY - 4.5, width: 4.2, height: 6),
                                       xRadius: 2.1, yRadius: 2.1)
            titleInk.withAlphaComponent(0.55).setStroke(); shackle.lineWidth = 1.1; shackle.stroke()
            u.draw(at: CGPoint(x: lx + 12, y: pill.midY - us.height / 2))
        }
        let top = barH
        if w.url != nil {
            // Web page: no sidebar, centred column.
            (dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.6)).setFill()
            rr(CGRect(x: 60, y: top + 20, width: 200, height: 16), 4).fill()
            accent.withAlphaComponent(dark ? 0.55 : 0.28).setFill()
            rr(CGRect(x: 60, y: top + 50, width: rect.width - 120, height: 74), 8).fill()
            fg.setFill()
            for k in 0..<4 {
                let lw = (rect.width - 120) * [1.0, 0.92, 0.97, 0.7][k]
                rr(CGRect(x: 60, y: top + 142 + CGFloat(k) * 22, width: lw, height: 10), 3).fill()
            }
            return
        }
        fg.setFill()
        CGRect(x: 0, y: top, width: 110, height: rect.height - top).fill()
        accent.withAlphaComponent(0.85).setFill()
        rr(CGRect(x: 12, y: top + 16, width: 86, height: 14), 4).fill()
        fg.setFill()
        for k in 0..<5 {
            rr(CGRect(x: 12, y: top + 42 + CGFloat(k) * 22, width: 70 - CGFloat(k % 3) * 12, height: 10), 3).fill()
        }
        (dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.6)).setFill()
        rr(CGRect(x: 132, y: top + 18, width: 180, height: 16), 4).fill()
        accent.withAlphaComponent(dark ? 0.55 : 0.28).setFill()
        rr(CGRect(x: 132, y: top + 50, width: rect.width - 156, height: 74), 8).fill()
        fg.setFill()
        for k in 0..<5 {
            let lw = (rect.width - 156) * [1.0, 0.92, 0.97, 0.7, 0.85][k]
            rr(CGRect(x: 132, y: top + 142 + CGFloat(k) * 22, width: lw, height: 10), 3).fill()
        }
    }
}

let safariGitHub = DemoWindow(appPath: "/Applications/Safari.app", title: "SwitchMux — GitHub", accent: .systemBlue,
                              dark: false, url: "github.com/deepcoldy/switchmux")
let safariRelease = DemoWindow(appPath: "/Applications/Safari.app", title: "Release notes · v1.2.0", accent: .systemTeal,
                               dark: false, url: "github.com/deepcoldy/switchmux/releases")
let safariDocs = DemoWindow(appPath: "/Applications/Safari.app", title: "快速上手 · 文档", accent: .systemIndigo,
                            dark: false, url: "github.com/deepcoldy/switchmux#readme")
let gridWindows: [DemoWindow] = [
    safariGitHub,
    .init(appPath: "/System/Applications/Notes.app", title: "发布清单", accent: .systemYellow, dark: false),
    .init(appPath: "/System/Applications/Mail.app", title: "收件箱", accent: .systemBlue, dark: false),
    .init(appPath: "/System/Applications/Calendar.app", title: "本周", accent: .systemRed, dark: false),
    .init(appPath: "/System/Applications/Utilities/Terminal.app", title: "~/switchmux — zsh", accent: .systemGreen, dark: true),
    .init(appPath: "/System/Applications/Music.app", title: "最近播放", accent: .systemPink, dark: true),
    .init(appPath: "/System/Library/CoreServices/Finder.app", title: "应用程序", accent: .systemBlue, dark: false),
    safariRelease,
]
let safariWindows: [DemoWindow] = [safariGitHub, safariRelease, safariDocs]
var mockCache: [String: NSImage] = [:]
func mock(_ w: DemoWindow) -> NSImage {
    let key = w.appPath + w.title
    if let m = mockCache[key] { return m }
    let m = windowMock(w)
    mockCache[key] = m
    return m
}

/// A desktop window (mock with shadow), optionally coming forward with
/// the shared 0.97 → 1 scale + fade.
func desktopWindow(_ w: DemoWindow, _ r: CGRect, forward: Double = 1) {
    group(alpha: forward) {
        scaled(mix(0.97, 1, forward), around: CGPoint(x: r.midX, y: r.midY)) {
            ctx.saveGState(); shadow(40, 16, 0.22); fill(rr(r, 12), .white); ctx.restoreGState()
            drawImage(mock(w), in: r, radius: 12)
            NSColor(white: 0, alpha: 0.08).setStroke()
            let e = rr(r.insetBy(dx: 0.5, dy: 0.5), 12); e.lineWidth = 1; e.stroke()
        }
    }
}

/// Soft abstract desktop: warm gradient with blurred color fields.
let desktopRect = CGRect(x: 160, y: 340, width: 1600, height: 640)
let desktopImage: NSImage = bitmap(desktopRect.size, scale: 1) {
    let r = CGRect(origin: .zero, size: desktopRect.size)
    let base = NSGradient(colors: [hex(0xEEE8DC), hex(0xE5D9C9)])!
    base.draw(in: r, angle: -70)
    func blob(_ c: NSColor, _ center: CGPoint, _ radius: CGFloat) {
        let g = NSGradient(colors: [c, c.withAlphaComponent(0)])!
        g.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
    blob(hex(0xD97757, 0.30), CGPoint(x: 1260, y: 120), 640)
    blob(hex(0xC9B79C, 0.45), CGPoint(x: 220, y: 600), 560)
    blob(hex(0xFAF9F5, 0.75), CGPoint(x: 640, y: 160), 520)
    blob(hex(0xBFC6C0, 0.30), CGPoint(x: 1500, y: 620), 420)
    // Menu bar strip with neutral placeholders.
    NSColor(white: 1, alpha: 0.38).setFill()
    CGRect(x: 0, y: 0, width: r.width, height: 30).fill()
    NSColor(white: 0, alpha: 0.22).setFill()
    for (i, w) in [18.0, 46, 38, 52, 40].enumerated() {
        let x = 22 + [0.0, 34, 96, 150, 218][i]
        rr(CGRect(x: x, y: 11, width: w, height: 8), 4).fill()
    }
    for (i, w) in [16.0, 16, 60].enumerated() {
        rr(CGRect(x: r.width - 140 + [0.0, 28, 56][i], y: 11, width: w, height: 8), 4).fill()
    }
}

func drawDesktop(alpha: Double, rise: CGFloat) {
    group(alpha: alpha, dy: rise) {
        ctx.saveGState(); shadow(50, 18, 0.10); fill(rr(desktopRect, 28), hex(0xE9E2D5)); ctx.restoreGState()
        drawImage(desktopImage, in: desktopRect, radius: 28)
        NSColor(white: 0, alpha: 0.05).setStroke()
        let p = rr(desktopRect.insetBy(dx: 0.5, dy: 0.5), 28); p.lineWidth = 1; p.stroke()
    }
}

// MARK: - Components

/// A physical key cap. `pressed` 0...1.
func keycap(_ label: String, sub: String? = nil, x: CGFloat, y: CGFloat, w: CGFloat = 104,
            pressed: Double, labelFont: NSFont = system(44, .medium),
            glyph: ((CGRect, NSColor) -> Void)? = nil) {
    let h: CGFloat = 104
    let down = CGFloat(pressed) * 4
    let r = CGRect(x: x, y: y + down, width: w, height: h)
    ctx.saveGState(); shadow(18 - 10 * CGFloat(pressed), 8 - 6 * CGFloat(pressed), 0.10)
    fill(rr(r, 20), mixColor(.white, hex(0xF6F1E8), pressed)); ctx.restoreGState()
    let border = rr(r.insetBy(dx: 0.75, dy: 0.75), 20)
    mixColor(line, clay, pressed * 0.9).setStroke(); border.lineWidth = 1.5; border.stroke()
    let color = mixColor(ink, clay, pressed)
    if let glyph = glyph {
        glyph(CGRect(x: r.minX, y: r.minY + 8, width: w, height: h - 34), color)
        if let sub = sub { textCentered(attr(sub, sans(15), mixColor(gray, clay, pressed)), cx: r.midX, y: r.maxY - 32) }
    } else if let sub = sub {
        textCenteredIn(attr(label, labelFont, color), CGRect(x: r.minX, y: r.minY + 8, width: w, height: h - 34))
        textCentered(attr(sub, sans(15), mixColor(gray, clay, pressed)), cx: r.midX, y: r.maxY - 32)
    } else {
        textCenteredIn(attr(label, labelFont, color), r)
    }
}

/// Key legend for the backtick key: a bold, optically centred tick with the
/// shifted "~" to its upper left, like a real keycap.
func backtickGlyph(_ r: CGRect, _ color: NSColor) {
    let c = CGPoint(x: r.midX + 6, y: r.midY + 4)
    let tick = NSBezierPath()
    tick.move(to: CGPoint(x: c.x - 7, y: c.y - 10))
    tick.line(to: CGPoint(x: c.x + 5, y: c.y + 6))
    tick.lineWidth = 7; tick.lineCapStyle = .round
    color.setStroke(); tick.stroke()
    text(attr("~", system(30, .medium), color.withAlphaComponent(0.55)), x: r.minX + 22, y: r.minY + 2)
}

func pressCurve(_ t: Double, _ down: Double, _ up: Double?) -> Double {
    let d = prog(t, down, 0.14)
    guard let up = up else { return d }
    return d * (1 - prog(t, up, 0.18))
}

/// The floating app bar (geometry of the real bar, in bar points: 644 x 102).
func appBar(origin: CGPoint, scale s: CGFloat, highlight: Int, amount: Double, activeDots: Set<Int>) {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: s, y: s)
    let bar = CGRect(x: 0, y: 0, width: 644, height: 102)
    ctx.saveGState(); shadow(40 / s, 16 / s, 0.28); fill(rr(bar, 20), NSColor(white: 0.11, alpha: 0.96)); ctx.restoreGState()
    NSColor(white: 1, alpha: 0.10).setStroke()
    let edge = rr(bar.insetBy(dx: 0.5, dy: 0.5), 20); edge.lineWidth = 1 / s; edge.stroke()
    for i in barApps.indices {
        let ir = CGRect(x: 18 + CGFloat(i) * 70, y: 14, width: 48, height: 48)
        let a = i == highlight ? amount : 0
        if a > 0 {
            fill(rr(ir.insetBy(dx: -8, dy: -7), 13), NSColor(white: 1, alpha: 0.20 * CGFloat(a)))
        }
        scaled(1 + 0.07 * CGFloat(a), around: CGPoint(x: ir.midX, y: ir.midY)) {
            drawImage(barIcons[i], in: ir)
            let badge = CGRect(x: ir.minX + 1, y: ir.minY + 30, width: 17, height: 17)
            fill(rr(badge, 4.5), NSColor(white: 0.12, alpha: 0.88))
            textCenteredIn(attr(barApps[i].key, system(11, .bold), .white), badge.offsetBy(dx: 0.3, dy: 0))
        }
        let on = activeDots.contains(i)
        let dot = CGRect(x: ir.midX - 2.5, y: 85.5, width: 5, height: 5)
        fill(NSBezierPath(ovalIn: dot), NSColor(white: 1, alpha: on ? 0.85 : 0.32))
    }
    ctx.restoreGState()
}

struct Grid { let origin: CGPoint; let cols: Int; let cardW: CGFloat; let thumbH: CGFloat; let gap: CGFloat; let pad: CGFloat
    var labelH: CGFloat { 50 }
    var cardH: CGFloat { thumbH + labelH + 10 }
    func card(_ i: Int) -> CGRect {
        let c = i % cols, r = i / cols
        return CGRect(x: origin.x + pad + CGFloat(c) * (cardW + gap), y: origin.y + pad + CGFloat(r) * (cardH + gap),
                      width: cardW, height: cardH)
    }
    func panel(count: Int) -> CGRect {
        let rows = (count + cols - 1) / cols
        let n = min(count, cols)
        return CGRect(x: origin.x, y: origin.y, width: pad * 2 + CGFloat(n) * cardW + CGFloat(n - 1) * gap,
                      height: pad * 2 + CGFloat(rows) * cardH + CGFloat(rows - 1) * gap)
    }
}

/// The window switcher panel: thumbnail cards with a moving selection ring.
func switcher(_ items: [DemoWindow], grid g: Grid, selection: CGRect, keys: [String]) {
    let panel = g.panel(count: items.count)
    ctx.saveGState(); shadow(50, 20, 0.28); fill(rr(panel, 24), NSColor(white: 0.17, alpha: 0.95)); ctx.restoreGState()
    NSColor(white: 1, alpha: 0.10).setStroke()
    let edge = rr(panel.insetBy(dx: 0.5, dy: 0.5), 24); edge.lineWidth = 1; edge.stroke()
    // Selection backdrop under the cards.
    fill(rr(selection.insetBy(dx: -4, dy: -4), 16), NSColor(white: 1, alpha: 0.13))
    for (i, w) in items.enumerated() {
        let c = g.card(i)
        let thumb = CGRect(x: c.minX + 8, y: c.minY + 8, width: c.width - 16, height: g.thumbH - 6)
        drawImage(mock(w), in: thumb, radius: 9)
        if i < keys.count {
            let b = CGRect(x: thumb.minX + 8, y: thumb.minY + 6, width: 22, height: 22)
            fill(rr(b, 6), NSColor(white: 0.10, alpha: 0.85))
            textCenteredIn(attr(keys[i], system(13, .bold), .white), b)
        }
        let iconR = CGRect(x: c.minX + 12, y: thumb.maxY + 14, width: 24, height: 24)
        drawImage(icon(w.appPath), in: iconR)
        text(attr(w.title, sans(16, "Medium"), NSColor(white: 1, alpha: 0.92)), x: iconR.maxX + 9, y: iconR.minY + 1)
    }
    let ring = rr(selection.insetBy(dx: -4, dy: -4), 16)
    NSColor(white: 1, alpha: 0.95).setStroke(); ring.lineWidth = 3; ring.stroke()
}

/// Eyebrow + headline + optional subtitle, top-left aligned.
func header(_ t: Double, eyebrow: String, title: String, subtitle: String?, subtitleAt: Double = 0.55,
            then next: (String, Double)? = nil,
            x: CGFloat = 160, y: CGFloat = 108, titleSize: CGFloat = 68, maxWidth: CGFloat = 1100) {
    reveal(t, 0.0) { text(attr(eyebrow, sans(20, "Medium"), clay, kern: 3), x: x, y: y) }
    var hy = y + 40
    reveal(t, 0.12) {
        let a = attr(title, serif(titleSize), ink, kern: 1, lineHeight: titleSize * 1.32)
        let r = a.boundingRect(with: CGSize(width: maxWidth, height: 600), options: [.usesLineFragmentOrigin])
        a.draw(with: CGRect(x: x, y: hy, width: maxWidth, height: r.height), options: [.usesLineFragmentOrigin])
    }
    let a = attr(title, serif(titleSize), ink, kern: 1, lineHeight: titleSize * 1.32)
    hy += a.boundingRect(with: CGSize(width: maxWidth, height: 600), options: [.usesLineFragmentOrigin]).height + 14
    if let s = subtitle {
        // Optional crossfade to a second line at `next.1`.
        let out = next.map { prog(t, $0.1, 0.4) } ?? 0
        group(alpha: 1 - out, dy: -10 * CGFloat(out)) {
            reveal(t, subtitleAt) { text(attr(s, sans(26, "Light"), ink2, kern: 0.5), x: x, y: hy) }
        }
        if let (s2, at) = next {
            reveal(t, at + 0.25, dur: 0.6, rise: 10) { text(attr(s2, sans(26, "Light"), ink2, kern: 0.5), x: x, y: hy) }
        }
    }
}

// MARK: - Scenes

struct Scene { let duration: Double; let draw: (Double) -> Void }

let settingsShot = asset("settings-apps@2x.png")
let settingsBounds = opaqueBounds(settingsShot)
let guideShot = asset("permission-guide@2x.png")
let guideGrantedShot = asset("permission-guide-granted@2x.png")

/// CJK tagline: modest tracking and a darker ink so Songti holds its weight.
let tagInk = ink.withAlphaComponent(0.8)

let scenes: [Scene] = [
    // 1. Title
    Scene(duration: 4.5) { t in
        let cx = WF / 2
        reveal(t, 0.15, dur: 0.9, rise: 14) {
            let r = CGRect(x: cx - 100, y: 220, width: 200, height: 200)
            ctx.saveGState(); shadow(40, 14, 0.12); drawImage(switchMuxIcon, in: r); ctx.restoreGState()
        }
        reveal(t, 0.6, dur: 0.9) { textCentered(attr("SwitchMux", serif(124), ink, kern: 1), cx: cx, y: 470) }
        reveal(t, 1.2, dur: 0.9) {
            textCentered(attr("在应用与窗口之间，一步抵达。", serif(46), tagInk, kern: 1.2), cx: cx, y: 660)
        }
        reveal(t, 1.8, dur: 0.8, rise: 0) {
            fill(rr(CGRect(x: cx - 28, y: 770, width: 56, height: 3), 1.5), clay)
        }
    },

    // 2. ⌥ + key → app bar
    Scene(duration: 7.0) { t in
        header(t, eyebrow: "01 · 应用切换", title: "按住 ⌥，按一个键。",
               subtitle: "每个应用一个键位，打开、切换或隐藏，一次完成。")
        let optP = pressCurve(t, 1.0, 3.5), twoP = pressCurve(t, 2.5, 3.1)
        reveal(t, 0.5) { keycap("⌥", sub: "option", x: 1540, y: 120, pressed: optP) }
        reveal(t, 0.65) { keycap("2", x: 1656, y: 120, pressed: twoP) }

        // Windows on the desktop: Notes first, Safari comes forward after "2".
        reveal(t, 0.6, dur: 0.8, rise: 10) {
            desktopWindow(gridWindows[1], CGRect(x: 300, y: 420, width: 640, height: 400))
        }
        desktopWindow(safariGitHub, CGRect(x: 820, y: 450, width: 760, height: 475), forward: prog(t, 3.5, 0.7))
        // App bar appears while ⌥ is held, leaves when it is released.
        let barIn = prog(t, 1.15, 0.5) * (1 - prog(t, 3.55, 0.4))
        let s: CGFloat = 1.7
        let bw = 644 * s
        group(alpha: barIn, dy: 14 * CGFloat(1 - barIn)) {
            appBar(origin: CGPoint(x: desktopRect.midX - bw / 2, y: desktopRect.midY - 102 * s / 2 + 10),
                   scale: s, highlight: 1, amount: prog(t, 2.5, 0.3), activeDots: [0, 3, 7])
        }
    },

    // 3. ⌘Tab grid, then a quick tap back to the previous window
    Scene(duration: 8.9) { t in
        header(t, eyebrow: "02 · 窗口切换", title: "⌘Tab，看见每一个窗口。",
               subtitle: "按住 ⌘ 连按 Tab 挑选，松开即到达。",
               then: ("快按一下，回到上一个窗口。", 5.0))
        let tap = 5.0
        let tabP = pressCurve(t, 1.5, 1.75) + pressCurve(t, 2.4, 2.65) + pressCurve(t, 3.3, 3.55)
            + pressCurve(t, tap + 0.05, tap + 0.17)
        let cmdP = pressCurve(t, 1.0, 4.0) + pressCurve(t, tap, tap + 0.2)
        reveal(t, 0.5) { keycap("⌘", sub: "command", x: 1478, y: 120, pressed: min(1, cmdP)) }
        reveal(t, 0.65) { keycap("tab", x: 1594, y: 120, w: 166, pressed: min(1, tabP), labelFont: system(30, .medium)) }
        // Safari (from scene 01) is the current window.
        let safariR = CGRect(x: 820, y: 450, width: 760, height: 475)
        let calR = CGRect(x: 340, y: 420, width: 760, height: 475)
        reveal(t, 0.0, dur: 0.5, rise: 0) { desktopWindow(safariGitHub, safariR) }
        let g0 = Grid(origin: .zero, cols: 4, cardW: 300, thumbH: 188, gap: 18, pad: 22)
        let size = g0.panel(count: gridWindows.count).size
        let g = Grid(origin: CGPoint(x: desktopRect.midX - size.width / 2, y: desktopRect.midY - size.height / 2 + 14),
                     cols: 4, cardW: 300, thumbH: 188, gap: 18, pad: 22)
        // After release: the chosen window (Calendar 本周) is in front …
        desktopWindow(gridWindows[3], calR, forward: prog(t, 4.1, 0.7))
        // … and a quick ⌘Tab tap brings Safari back.
        desktopWindow(safariGitHub, safariR, forward: prog(t, tap + 0.25, 0.6))
        let sel = mixRect(mixRect(mixRect(g.card(0), g.card(1), prog(t, 1.5, 0.35)), g.card(2), prog(t, 2.4, 0.35)),
                          g.card(3), prog(t, 3.3, 0.35))
        let p = prog(t, 1.1, 0.5) * (1 - prog(t, 4.0, 0.4))
        group(alpha: p) {
            scaled(mix(0.98, 1, p), around: CGPoint(x: desktopRect.midX, y: desktopRect.midY)) {
                switcher(gridWindows, grid: g, selection: sel, keys: (1...8).map(String.init))
            }
        }
    },

    // 4. ⌥` same-app windows
    Scene(duration: 6.5) { t in
        header(t, eyebrow: "03 · 同应用窗口", title: "⌥`，同一应用的多个窗口。",
               subtitle: "在当前应用的窗口之间轮换，不打扰其他应用。")
        let presses = [1.5, 2.4]
        let release = 3.4
        let tickP = presses.map { pressCurve(t, $0, $0 + 0.25) }.reduce(0, +)
        reveal(t, 0.5) { keycap("⌥", sub: "option", x: 1540, y: 120, pressed: pressCurve(t, 1.0, release)) }
        reveal(t, 0.65) { keycap("`", sub: "backtick", x: 1656, y: 120, pressed: tickP, glyph: backtickGlyph) }
        // Three stacked Safari windows; GitHub is in front.
        let back = [CGRect(x: 380, y: 410, width: 700, height: 437), CGRect(x: 1000, y: 430, width: 700, height: 437)]
        reveal(t, 0.0, dur: 0.6, rise: 0) {
            desktopWindow(safariRelease, back[1])
            desktopWindow(safariDocs, back[0])
            desktopWindow(safariGitHub, CGRect(x: 640, y: 470, width: 700, height: 437))
        }
        // On release the selected window (快速上手 · 文档) is raised in place.
        desktopWindow(safariDocs, back[0], forward: prog(t, release + 0.1, 0.7))
        let g0 = Grid(origin: .zero, cols: 3, cardW: 400, thumbH: 250, gap: 22, pad: 24)
        let size = g0.panel(count: 3).size
        let g = Grid(origin: CGPoint(x: desktopRect.midX - size.width / 2, y: desktopRect.midY - size.height / 2 + 14),
                     cols: 3, cardW: 400, thumbH: 250, gap: 22, pad: 24)
        // 0 → 1 → 2
        var sel = g.card(0)
        sel = mixRect(sel, g.card(1), prog(t, presses[0], 0.35))
        sel = mixRect(sel, g.card(2), prog(t, presses[1], 0.35))
        let p = prog(t, 1.1, 0.5) * (1 - prog(t, release, 0.4))
        group(alpha: p) {
            scaled(mix(0.98, 1, p), around: CGPoint(x: desktopRect.midX, y: desktopRect.midY)) {
                switcher(safariWindows, grid: g, selection: sel, keys: ["1", "2", "3"])
            }
        }
    },

    // 5. Settings list
    Scene(duration: 5.5) { t in
        let x: CGFloat = 160
        reveal(t, 0.0) { text(attr("04 · 配置", sans(20, "Medium"), clay, kern: 3), x: x, y: 300) }
        reveal(t, 0.12) {
            let a = attr("一个列表，\n就是全部配置。", serif(68), ink, kern: 1, lineHeight: 92)
            a.draw(with: CGRect(x: x, y: 340, width: 640, height: 200), options: [.usesLineFragmentOrigin])
        }
        let bullets = ["拖动行，调整顺序", "点按键位，重新录制", "把 .app 拖进来，即可添加"]
        for (i, b) in bullets.enumerated() {
            reveal(t, 1.4 + Double(i) * 0.35) {
                let y = 560 + CGFloat(i) * 52
                fill(NSBezierPath(ovalIn: CGRect(x: x + 2, y: y + 14, width: 8, height: 8)), clay)
                text(attr(b, sans(26, "Light"), ink2), x: x + 26, y: y)
            }
        }
        // Light-mode screenshot (2x capture, downscaled) in a rounded window frame.
        let s: CGFloat = 1.18
        let content = CGSize(width: settingsBounds.width * s, height: settingsBounds.height * s)
        let titleH: CGFloat = 44
        let frame = CGRect(x: 1765 - content.width, y: 540 - (content.height + titleH) / 2,
                           width: content.width, height: content.height + titleH)
        reveal(t, 0.35, dur: 0.8, rise: 24) {
            softPanel(frame, radius: 16, color: .white, strength: 1.6)
            NSGraphicsContext.saveGraphicsState()
            rr(frame, 16).addClip()
            fill(NSBezierPath(rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleH)), hex(0xF6F5F1))
            fill(NSBezierPath(rect: CGRect(x: frame.minX, y: frame.minY + titleH - 1, width: frame.width, height: 1)), line)
            for (j, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
                fill(NSBezierPath(ovalIn: CGRect(x: frame.minX + 18 + CGFloat(j) * 20, y: frame.minY + 16, width: 12, height: 12)), c)
            }
            textCenteredIn(attr("SwitchMux 设置", sans(14, "Medium"), ink2),
                           CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleH))
            // Map the opaque part of the screenshot into the frame body.
            let full = CGRect(x: frame.minX - settingsBounds.minX * s, y: frame.minY + titleH - settingsBounds.minY * s,
                              width: settingsShot.size.width * s, height: settingsShot.size.height * s)
            drawImage(settingsShot, in: full)
            NSGraphicsContext.restoreGraphicsState()
            line.setStroke()
            let e = rr(frame.insetBy(dx: 0.5, dy: 0.5), 16); e.lineWidth = 1; e.stroke()
        }
        // Gentle clay ring around the shortcut column.
        reveal(t, 2.6, dur: 0.7, rise: 0) {
            let col = CGRect(x: frame.minX + (684 - settingsBounds.minX) * s, y: frame.minY + titleH + (84 - settingsBounds.minY) * s,
                             width: 40 * s, height: 392 * s)
            let ring = rr(col, 12); clay.setStroke(); ring.lineWidth = 2.5; ring.stroke()
        }
    },

    // 6. Permission: drag once, then flip the switch
    Scene(duration: 6.5) { t in
        let x: CGFloat = 160
        reveal(t, 0.0) { text(attr("05 · 授权", sans(20, "Medium"), clay, kern: 3), x: x, y: 330) }
        reveal(t, 0.12) {
            text(attr("授权，只需拖一下。", serif(68), ink, kern: 1), x: x, y: 370)
        }
        reveal(t, 0.9) {
            let a = attr("把图标拖进「辅助功能」列表，\n打开开关，即可开始使用。", sans(26, "Light"), ink2, lineHeight: 44)
            a.draw(with: CGRect(x: x, y: 490, width: 620, height: 120), options: [.usesLineFragmentOrigin])
        }
        // Accessibility settings mock (light) + docked guide (light 2x capture).
        let win = CGRect(x: 960, y: 215, width: 800, height: 400)
        let rowH: CGFloat = 60
        let list = CGRect(x: win.minX + 28, y: win.minY + 112, width: win.width - 56, height: rowH * 2)
        let newRow = prog(t, 3.0, 0.45)
        let toggleOn = prog(t, 3.95, 0.35)
        let toggleRect = CGRect(x: list.maxX - 66, y: list.minY + rowH * 2 + 18, width: 44, height: 24)
        reveal(t, 0.3, dur: 0.8, rise: 20) {
            softPanel(win, radius: 16, color: .white, strength: 1.4)
            NSGraphicsContext.saveGraphicsState(); rr(win, 16).addClip()
            fill(NSBezierPath(rect: CGRect(x: win.minX, y: win.minY, width: win.width, height: 56)), hex(0xF6F5F1))
            NSGraphicsContext.restoreGraphicsState()
            for (j, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
                fill(NSBezierPath(ovalIn: CGRect(x: win.minX + 20 + CGFloat(j) * 20, y: win.minY + 22, width: 12, height: 12)), c)
            }
            text(attr("‹   辅助功能", sans(17, "Semibold"), ink), x: win.minX + 104, y: win.minY + 16)
            text(attr("允许下面的应用程序控制你的电脑。", sans(15), ink2), x: win.minX + 30, y: win.minY + 74)
            let lr = CGRect(x: list.minX, y: list.minY, width: list.width, height: list.height + rowH * CGFloat(newRow))
            fill(rr(lr, 12), hex(0xFBFAF7))
            line.setStroke(); let lp = rr(lr.insetBy(dx: 0.5, dy: 0.5), 12); lp.lineWidth = 1; lp.stroke()
            func row(_ i: Int, _ name: String, _ img: NSImage, on: Double, alpha: Double) {
                group(alpha: alpha) {
                    let y = list.minY + CGFloat(i) * rowH
                    if i > 0 { fill(NSBezierPath(rect: CGRect(x: list.minX + 16, y: y, width: list.width - 32, height: 1)), line) }
                    drawImage(img, in: CGRect(x: list.minX + 18, y: y + 14, width: 32, height: 32))
                    text(attr(name, sans(16), ink), x: list.minX + 64, y: y + 18)
                    let tg = CGRect(x: list.maxX - 66, y: y + 18, width: 44, height: 24)
                    fill(rr(tg, 12), mixColor(hex(0xDAD8D0), hex(0x3478F6), on))
                    let knob = CGRect(x: mix(tg.minX + 2, tg.maxX - 22, on), y: tg.minY + 2, width: 20, height: 20)
                    ctx.saveGState(); shadow(3, 1, 0.2); fill(NSBezierPath(ovalIn: knob), .white); ctx.restoreGState()
                }
            }
            row(0, "终端", icon("/System/Applications/Utilities/Terminal.app"), on: 1, alpha: 1)
            row(1, "脚本编辑器", icon("/System/Applications/Utilities/Script Editor.app"), on: 1, alpha: 1)
            row(2, "SwitchMux", switchMuxIcon, on: toggleOn, alpha: newRow)
            let by = win.maxY - 46
            text(attr("+    −", system(20), ink2), x: win.minX + 34, y: by)
        }
        let gs: CGFloat = 1.25
        let guide = CGRect(x: win.minX + 28, y: win.maxY + 30, width: guideShot.size.width * gs, height: guideShot.size.height * gs)
        // The guide crossfades to its granted state once the switch is on.
        let granted = prog(t, 4.2, 0.45)
        reveal(t, 0.7, dur: 0.8, rise: 20) {
            ctx.saveGState(); shadow(36, 14, 0.16); drawImage(guideShot, in: guide, radius: 12 * gs); ctx.restoreGState()
            if granted > 0 { drawImage(guideGrantedShot, in: guide, alpha: CGFloat(granted), radius: 12 * gs) }
        }
        // Drag the tile from the guide into the list …
        let start = CGPoint(x: guide.minX + 53 * gs, y: guide.minY + 70 * gs)
        let end = CGPoint(x: list.minX + 34, y: list.minY + rowH * 2 + 30)
        let d = prog(t, 1.8, 1.1)
        let visible = prog(t, 1.6, 0.25) * (1 - prog(t, 2.95, 0.25))
        let lift = sin(d * .pi) * 60
        let p = CGPoint(x: mix(start.x, end.x, d) - CGFloat(lift) * 0.4, y: mix(start.y, end.y, d) - CGFloat(lift))
        group(alpha: visible) {
            let r = CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60)
            ctx.saveGState(); shadow(16, 8, 0.25); drawImage(switchMuxIcon, in: r, alpha: 0.92); ctx.restoreGState()
        }
        // … then move to the switch and click it.
        let toToggle = prog(t, 3.2, 0.6)
        let target = CGPoint(x: toggleRect.midX - 4, y: toggleRect.midY - 2)
        let cp = d < 0.999 ? p : CGPoint(x: mix(end.x, target.x, toToggle), y: mix(end.y, target.y, toToggle))
        let click = pressCurve(t, 3.82, 3.96)
        let cursorAlpha = prog(t, 1.5, 0.3) * (1 - prog(t, 5.0, 0.3))
        group(alpha: cursorAlpha) {
            let cur = NSCursor.arrow.image
            let s: CGFloat = 1.4 * mix(1, 0.96, click)
            drawImage(cur, in: CGRect(x: cp.x + 8, y: cp.y + 6, width: cur.size.width * s, height: cur.size.height * s))
        }
    },

    // 7. Closing
    Scene(duration: 6.0) { t in
        let cx = WF / 2
        reveal(t, 0.3, dur: 0.9, rise: 14) {
            let r = CGRect(x: cx - 88, y: 230, width: 176, height: 176)
            ctx.saveGState(); shadow(40, 14, 0.12); drawImage(switchMuxIcon, in: r); ctx.restoreGState()
        }
        reveal(t, 0.7, dur: 0.9) { textCentered(attr("SwitchMux", serif(104), ink, kern: 1), cx: cx, y: 440) }
        reveal(t, 1.3, dur: 0.9) {
            textCentered(attr("免费 · 开源 · macOS 13+", sans(30, "Light"), ink2, kern: 2), cx: cx, y: 610)
        }
        reveal(t, 1.8, dur: 0.8, rise: 0) {
            fill(rr(CGRect(x: cx - 28, y: 690, width: 56, height: 3), 1.5), clay)
        }
        reveal(t, 2.1, dur: 0.9) {
            textCentered(attr("github.com/deepcoldy/switchmux", sans(28), clay, kern: 1), cx: cx, y: 730)
        }
    },
]

let starts: [Double] = scenes.indices.map { i in scenes[..<i].reduce(0) { $0 + $1.duration } }
let total = scenes.reduce(0) { $0 + $1.duration }
let fadeOut = 0.5

// MARK: - Frame

func drawFrame(_ T: Double) {
    ivory.setFill(); CGRect(x: 0, y: 0, width: WF, height: HF).fill()

    // The desktop persists across scenes 2–4.
    let dIn = prog(T, starts[1] + 0.1, 0.8), dOut = prog(T, starts[4] - 0.55, 0.5)
    drawDesktop(alpha: dIn * (1 - dOut), rise: 20 * CGFloat(1 - dIn))

    for (i, s) in scenes.enumerated() where T >= starts[i] && T < starts[i] + s.duration {
        let local = T - starts[i]
        let isLast = i == scenes.count - 1
        let a = isLast ? 1 : 1 - prog(local, s.duration - fadeOut, fadeOut)
        group(alpha: a) { s.draw(local) }
    }

    // Quiet footer mark during the feature scenes.
    let fIn = prog(T, starts[1] + 0.3, 0.8), fOut = prog(T, starts[6] - 0.5, 0.5)
    group(alpha: fIn * (1 - fOut)) {
        fill(NSBezierPath(ovalIn: CGRect(x: 160, y: 1029, width: 8, height: 8)), clay)
        text(attr("SwitchMux", serif(20), gray, kern: 0.5), x: 178, y: 1018)
        let label = attr("github.com/deepcoldy/switchmux", sans(16), gray, kern: 0.5)
        text(label, x: 1760 - label.size().width, y: 1021)
    }
    // Opening fade from ivory.
    group(alpha: 1 - prog(T, 0, 0.4)) { ivory.setFill(); CGRect(x: 0, y: 0, width: WF, height: HF).fill() }
}

func withFrameContext(_ c: CGContext, _ body: () -> Void) {
    c.translateBy(x: 0, y: HF)
    c.scaleBy(x: 1, y: -1)
    let g = NSGraphicsContext(cgContext: c, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    ctx = c
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func renderPNG(_ T: Double, to path: String, poster: Bool = false) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    withFrameContext(c) { poster ? drawPoster() : drawFrame(T) }
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Hero frame: title on the left, the app bar over the desktop on the right.
func drawPoster() {
    ivory.setFill(); CGRect(x: 0, y: 0, width: WF, height: HF).fill()
    let d = CGRect(x: 860, y: 160, width: 900, height: 760)
    ctx.saveGState(); shadow(50, 18, 0.10); fill(rr(d, 28), hex(0xE9E2D5)); ctx.restoreGState()
    drawImage(desktopImage, in: d, radius: 28)
    desktopWindow(safariGitHub, CGRect(x: 960, y: 270, width: 700, height: 437))
    let s: CGFloat = 1.25
    appBar(origin: CGPoint(x: d.midX - 644 * s / 2, y: 720), scale: s, highlight: 1, amount: 1, activeDots: [0, 1, 3, 7])
    let x: CGFloat = 160
    drawImage(switchMuxIcon, in: CGRect(x: x, y: 300, width: 132, height: 132))
    text(attr("SwitchMux", serif(104), ink, kern: 1), x: x, y: 450)
    text(attr("在应用与窗口之间，一步抵达。", serif(40), tagInk, kern: 1.2), x: x, y: 600)
    fill(rr(CGRect(x: x, y: 690, width: 56, height: 3), 1.5), clay)
    text(attr("免费 · 开源 · macOS 13+", sans(24, "Light"), ink2, kern: 1.5), x: x, y: 720)
    text(attr("github.com/deepcoldy/switchmux", sans(22), clay, kern: 0.5), x: x, y: 764)
}

// MARK: - Encode

func encode(to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_600_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 90,
            AVVideoExpectedSourceFrameRateKey: FPS,
        ],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "promo", code: 1) }
    writer.startSession(atSourceTime: .zero)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let frames = Int((total * Double(FPS)).rounded())
    for f in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let buf = pb else { throw NSError(domain: "promo", code: 2) }
        CVPixelBufferLockBaseAddress(buf, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        autoreleasepool { withFrameContext(c) { drawFrame(Double(f) / Double(FPS)) } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        if !adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS))) {
            throw writer.error ?? NSError(domain: "promo", code: 3)
        }
        if f % 150 == 0 { print("frame \(f)/\(frames)") }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "promo", code: 4) }
    print("wrote \(path): \(frames) frames, \(total) s")
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
_ = NSApplication.shared
if args.first == "--still", args.count == 3, let T = Double(args[1]) {
    renderPNG(T, to: args[2])
} else if args.first == "--poster", args.count == 2 {
    renderPNG(0, to: args[1], poster: true)
} else if let out = args.first {
    try encode(to: out)
    if args.count > 1 { renderPNG(0, to: args[1], poster: true); print("wrote \(args[1])") }
    print("scene starts: \(starts.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
} else {
    print("usage: render.swift <out.mp4> [poster.png] | --still <seconds> <out.png> | --poster <out.png>")
    exit(2)
}
