// SwitchMuxCaptureHelper — minimal privileged subprocess.
//
// Screen Recording permission is evaluated for a process when it connects to
// the window server and cannot be refreshed in-process after a grant (macOS
// forces a restart). Running captures in this short-lived helper instead means
// every invocation sees the CURRENT TCC state: thumbnails start working right
// after the user grants access, without relaunching SwitchMux itself.
//
// Usage:
//   SwitchMuxCaptureHelper probe
//       -> prints "granted" or "denied" by capturing any on-screen window.
//   SwitchMuxCaptureHelper capture <outputDir>
//       -> reads a JSON array [{id,x,y,w,h}] from stdin, writes <id>.png for
//          each NON-BLANK capture, prints one JSON result per line.

import AppKit
import CoreGraphics

struct CaptureJob: Codable {
    let id: UInt64
    let x: Double?
    let y: Double?
    let w: Double?
    let h: Double?
}

func blank(_ cg: CGImage) -> Bool {
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 4, h > 4 else { return true }
    var first: NSColor?
    var different = 0
    for _ in 0..<64 {
        let x = Int.random(in: 0..<w), y = Int.random(in: 0..<h)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if let f = first {
            if abs(c.redComponent - f.redComponent) > 0.04
                || abs(c.greenComponent - f.greenComponent) > 0.04
                || abs(c.blueComponent - f.blueComponent) > 0.04 {
                different += 1
            }
        } else {
            first = c
        }
    }
    return different < 3
}

func capture(_ job: CaptureJob) -> CGImage? {
    let bounds: CGRect
    if let x = job.x, let y = job.y, let w = job.w, let h = job.h, w > 1, h > 1 {
        bounds = CGRect(x: x, y: y, width: w, height: h)
    } else {
        bounds = CGRect.null
    }
    return CGWindowListCreateImage(
        bounds,
        .optionIncludingWindow,
        CGWindowID(job.id),
        [.boundsIgnoreFraming, .bestResolution, .nominalResolution]
    )
}

func firstOnScreenWindow() -> CGWindowID? {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for info in raw {
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard layer == 0, alpha > 0.9 else { continue }
        if let b = info[kCGWindowBounds as String] as? [String: CGFloat],
           let w = b["Width"], let h = b["Height"], w > 300, h > 200,
           let num = info[kCGWindowNumber as String] as? Int,
           let pid = info[kCGWindowOwnerPID as String] as? pid_t,
           pid != ProcessInfo.processInfo.processIdentifier {
            return CGWindowID(num)
        }
    }
    return nil
}

let args = CommandLine.arguments

if args.count >= 2 && args[1] == "probe" {
    if let id = firstOnScreenWindow(),
       let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                       [.boundsIgnoreFraming, .bestResolution]),
       cg.width > 8, cg.height > 8, !blank(cg) {
        print("granted")
    } else {
        print("denied")
    }
    exit(0)
}

if args.count >= 3 && args[1] == "capture" {
    let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let jobs = (try? JSONDecoder().decode([CaptureJob].self, from: input)) ?? []
    for job in jobs {
        guard let cg = capture(job) else {
            print("{\"id\":\(job.id),\"ok\":false}")
            continue
        }
        if blank(cg) {
            print("{\"id\":\(job.id),\"ok\":false}")
            continue
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("{\"id\":\(job.id),\"ok\":false}")
            continue
        }
        let url = outDir.appendingPathComponent("\(job.id).png")
        do {
            try png.write(to: url)
            print("{\"id\":\(job.id),\"ok\":true}")
        } catch {
            print("{\"id\":\(job.id),\"ok\":false}")
        }
    }
    exit(0)
}

FileHandle.standardError.write(Data("unknown command\n".utf8))
exit(2)
