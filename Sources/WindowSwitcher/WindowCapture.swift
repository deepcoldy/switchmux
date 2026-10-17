import AppKit

/// Runs the bundled SwitchMuxCaptureHelper subprocess to grab window images.
/// The helper is freshly launched per batch, so it sees the current Screen
/// Recording TCC state — thumbnails work immediately after the user grants
/// access, with no need to restart SwitchMux.
enum WindowCapture {
    private struct Job: Codable {
        let id: UInt64
        let x: Double?
        let y: Double?
        let w: Double?
        let h: Double?
    }

    private struct ResultLine: Codable { let id: UInt64; let ok: Bool }

    static var helperURL: URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "SwitchMuxCaptureHelper"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        // Running the unbundled debug binary: look next to the executable.
        let side = Bundle.main.bundleURL
            .appendingPathComponent("SwitchMuxCaptureHelper")
        if FileManager.default.isExecutableFile(atPath: side.path) { return side }
        return nil
    }

    static var isAvailable: Bool { helperURL != nil }

    // MARK: Probe (used by the settings pane)
    static func probe(completion: @escaping (Bool) -> Void) {
        run(args: ["probe"], input: nil, timeout: 2.0) { data, _ in
            completion(String(data: data ?? Data(), encoding: .utf8)?.contains("granted") ?? false)
        }
    }

    // MARK: Batch capture
    static func capture(_ items: [WindowItem], completion: @escaping ([CGWindowID: NSImage]) -> Void) {
        guard let _ = helperURL else { completion([:]); return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("switchmux-cap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let jobs = items.map {
            Job(id: UInt64($0.windowID),
                x: Double($0.frame.minX), y: Double($0.frame.minY),
                w: Double($0.frame.width), h: Double($0.frame.height))
        }
        guard let input = try? JSONEncoder().encode(jobs) else { completion([:]); return }

        run(args: ["capture", dir.path], input: input, timeout: 4.0) { data, _ in
            var images: [CGWindowID: NSImage] = [:]
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let okIDs = text.split(whereSeparator: { $0.isNewline })
                .compactMap { line -> UInt64? in
                    guard let data = line.data(using: .utf8),
                          let r = try? JSONDecoder().decode(ResultLine.self, from: data),
                          r.ok else { return nil }
                    return r.id
                }
            for id in okIDs {
                let url = dir.appendingPathComponent("\(id).png")
                if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                    images[CGWindowID(id)] = img
                }
            }
            try? FileManager.default.removeItem(at: dir)
            DispatchQueue.main.async { completion(images) }
        }
    }

    // MARK: Process
    private static func run(args: [String], input: Data?, timeout: TimeInterval,
                            completion: @escaping (Data?, Int32) -> Void) {
        guard let url = helperURL else { completion(nil, -1); return }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let input {
            let stdin = Pipe()
            p.standardInput = stdin
            stdin.fileHandleForWriting.write(input)
            stdin.fileHandleForWriting.closeFile()
        }
        let workItem = DispatchWorkItem {
            if p.isRunning { p.terminate() }
        }
        do {
            try p.run()
        } catch {
            completion(nil, -1)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
        DispatchQueue.global(qos: .userInitiated).async {
            p.waitUntilExit()
            workItem.cancel()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            completion(data, p.terminationStatus)
        }
    }
}
