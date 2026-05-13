import Foundation
import UIKit
import MetalKit
import SwiftUI

/// Snapshots the on-screen spectrogram view to a PNG and writes the last N seconds
/// of mic audio to a WAV file in the app's temp dir, then returns the URLs so the
/// caller can present them via `UIActivityViewController`.
enum Exporter {
    struct Output {
        let pngURL: URL?
        let wavURL: URL?
    }

    static func snapshot(view: UIView, name: String) -> URL? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("PNG write failed: \(error)")
            return nil
        }
    }

    static func writeRecentAudio(buffer: AudioRingBuffer,
                                  sampleRate: Double,
                                  seconds: Double,
                                  name: String) -> URL? {
        let n = max(1, Int(sampleRate * seconds))
        var samples = [Float](repeating: 0, count: n)
        let read = samples.withUnsafeMutableBufferPointer { p -> Int in
            buffer.peekRecent(n, into: p.baseAddress!)
        }
        guard read > 0 else { return nil }
        let trimmed = Array(samples.prefix(read))
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(name).wav")
        do {
            try WAVWriter.write(samples: trimmed, sampleRate: sampleRate, to: url)
            return url
        } catch {
            NSLog("WAV write failed: \(error)")
            return nil
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
