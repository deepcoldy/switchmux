// Renders the drag-to-install DMG background.
//
//   swift scripts/dmg_background.swift <out-dir>
//
// Writes <out-dir>/dmg_background.png (660x428 @1x) and
// <out-dir>/dmg_background@2x.png (1320x856). make_dmg.sh combines them
// into a HiDPI TIFF. The layout must match the icon positions in
// scripts/dmg_settings.py: app icon centre (170, 200), Applications
// centre (490, 200), icon size 128. Everything is laid out inside the top
// 400pt; the extra 28pt at the bottom is plain gradient, so the artwork
// survives Finder counting the title bar inside WindowBounds (or not).
import AppKit

let W: CGFloat = 660
let H: CGFloat = 428   // canvas height; layout lives in the top 400pt

// Calm ivory palette with a single warm accent. The image itself does not
// change with the appearance, but Finder draws icon labels black in Light
// Mode and white in Dark Mode, so the labels sit on a mid-tone chip
// (relative luminance ~0.18) that keeps ~4.5:1 contrast for either colour.
let bgTop    = NSColor(srgbRed: 0.988, green: 0.980, blue: 0.965, alpha: 1)
let bgBottom = NSColor(srgbRed: 0.957, green: 0.945, blue: 0.922, alpha: 1)
let ink      = NSColor(srgbRed: 0.118, green: 0.110, blue: 0.102, alpha: 1)
let inkSoft  = NSColor(srgbRed: 0.420, green: 0.400, blue: 0.375, alpha: 1)
let accent   = NSColor(srgbRed: 0.878, green: 0.478, blue: 0.247, alpha: 1)
let labelChip = NSColor(srgbRed: 0.520, green: 0.450, blue: 0.400, alpha: 1)

func font(_ names: [String], size: CGFloat, weight: NSFont.Weight) -> NSFont {
    for n in names { if let f = NSFont(name: n, size: size) { return f } }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

func drawCentered(_ text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: para, .kern: 0.4,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    str.draw(in: NSRect(x: 0, y: centerY - size.height / 2, width: W, height: size.height + 2))
}

func render(scale: CGFloat, to url: URL) throws {
    let pw = Int(W * scale), ph = Int(H * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw NSError(domain: "dmg_background", code: 1) }
    rep.size = NSSize(width: W, height: H)  // point size -> correct DPI metadata

    NSGraphicsContext.saveGraphicsState()
    // Flipped context so y grows downward, matching Finder icon coordinates.
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    // The rep's point size already maps points to pixels; only flip y.
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)

    // Background: soft vertical gradient.
    NSGradient(starting: bgTop, ending: bgBottom)!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    // Subtle drop zones behind the two icons (taller at the bottom so the
    // Finder label under each 128pt icon sits inside the card too).
    for cx in [CGFloat(170), 490] {
        let r = NSRect(x: cx - 84, y: 200 - 84, width: 168, height: 190)
        let p = NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30)
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55).setFill()
        p.fill()
        NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.05).setStroke()
        p.lineWidth = 1
        p.stroke()

        // Label chip: Finder puts the 13pt label right under the 128pt icon
        // (icon bottom at y=264), centred on the icon.
        let chip = NSRect(x: cx - 62, y: 265, width: 124, height: 26)
        labelChip.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 13, yRadius: 13).fill()
    }

    // Headline + hint.
    let headline = font(["PingFangSC-Semibold"], size: 22, weight: .semibold)
    drawCentered("拖到「应用程序」即可安装", font: headline, color: ink, centerY: 58)
    let hint = font(["PingFangSC-Regular"], size: 13, weight: .regular)
    drawCentered("然后从「应用程序」打开 SwitchMux，按提示授权辅助功能",
                 font: hint, color: inkSoft, centerY: 352)

    // Soft curved arrow from app to Applications (between the drop zones).
    let start = NSPoint(x: 268, y: 196)
    let end   = NSPoint(x: 388, y: 196)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end,
                controlPoint1: NSPoint(x: 300, y: 170),
                controlPoint2: NSPoint(x: 356, y: 170))
    arrow.lineWidth = 3.5
    arrow.lineCapStyle = .round
    accent.withAlphaComponent(0.9).setStroke()
    arrow.stroke()

    // Arrow head, aligned with the curve's end tangent.
    let angle = atan2(end.y - 170, end.x - 356)
    let len: CGFloat = 13, spread: CGFloat = 0.5
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - len * cos(angle - spread), y: end.y - len * sin(angle - spread)))
    head.line(to: end)
    head.line(to: NSPoint(x: end.x - len * cos(angle + spread), y: end.y - len * sin(angle + spread)))
    head.lineWidth = 3.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "dmg_background", code: 2) }
    try png.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift dmg_background.swift <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1, to: outDir.appendingPathComponent("dmg_background.png"))
try render(scale: 2, to: outDir.appendingPathComponent("dmg_background@2x.png"))
print("wrote \(outDir.path)/dmg_background.png and @2x")
