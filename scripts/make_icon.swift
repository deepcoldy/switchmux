import AppKit

// Renders SwitchMux.app icon: blue rounded-rect with a white ⌥ glyph.
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 224
let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
path.addClip()

let gradient = NSGradient(starting: NSColor(red: 0.30, green: 0.55, blue: 0.98, alpha: 1),
                          ending: NSColor(red: 0.10, green: 0.27, blue: 0.82, alpha: 1))
gradient?.draw(in: rect, angle: 90)

if let symbol = NSImage(systemSymbolName: "option", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let styled = symbol.withSymbolConfiguration(config) {
        let s = styled.size
        let drawRect = NSRect(x: (rect.width - s.width) / 2,
                              y: (rect.height - s.height) / 2,
                              width: s.width, height: s.height)
        styled.draw(in: drawRect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
