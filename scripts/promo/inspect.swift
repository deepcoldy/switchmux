// Prints duration / codec / size of a video and extracts PNG frames.
//
//   swift scripts/promo/inspect.swift <video.mp4> <out-dir> <t1> [t2 ...]

import AppKit
import AVFoundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: inspect.swift <video.mp4> <out-dir> [seconds ...]"); exit(2)
}
let url = URL(fileURLWithPath: args[0])
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let duration = try await asset.load(.duration)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "duration: %.2f s", duration.seconds))
        print(String(format: "size: %.2f MB (%d bytes)", Double(bytes) / 1_048_576, bytes))
        for track in try await asset.loadTracks(withMediaType: .video) {
            let (dims, fps, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
            let codecs = formats.map { desc -> String in
                let c = CMFormatDescriptionGetMediaSubType(desc).bigEndian
                return withUnsafeBytes(of: c) { String(decoding: $0, as: UTF8.self) }
            }
            print("video: \(Int(dims.width))x\(Int(dims.height)) @ \(fps) fps, codec \(codecs.joined(separator: ","))")
        }
        print("audio tracks: \(try await asset.loadTracks(withMediaType: .audio).count)")

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for s in args.dropFirst(2) {
            guard let t = Double(s) else { continue }
            let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: img)
            let file = outDir.appendingPathComponent(String(format: "frame-%05.1f.png", t))
            try rep.representation(using: .png, properties: [:])!.write(to: file)
            print("wrote \(file.path)")
        }
    } catch {
        print("error: \(error)")
    }
    sem.signal()
}
sem.wait()
