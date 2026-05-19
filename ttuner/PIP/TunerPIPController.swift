import AVKit
import CoreMedia
import CoreVideo
import QuartzCore
import SwiftUI
import UIKit

/// One pitch sample plotted in the PIP's scrolling history rail. The
/// view computes the dot's `y` from `renderTime − time`, so points just
/// rise on their own as time advances.
struct PIPPitchSample: Equatable {
    let time: CFTimeInterval
    let cents: Double
}

/// Drives the floating Picture-in-Picture tuner. Owns the
/// `AVSampleBufferDisplayLayer` that PIP shows, runs a CADisplayLink
/// at ~12 fps to rasterise `TunerPIPView` (SwiftUI) into the layer,
/// and asks iOS to auto-start PIP whenever the app backgrounds.
///
/// The "host view" is a tiny near-invisible square the app embeds in
/// its window — it exists purely to satisfy iOS's "source layer must
/// be on-screen" rule for `canStartPictureInPictureAutomaticallyFromInline`.
/// The user never notices it.
final class TunerPIPController: NSObject {
    static let shared = TunerPIPController()

    /// Layer that the system samples to draw the PIP window.
    let sampleBufferLayer = AVSampleBufferDisplayLayer()

    private var pip: AVPictureInPictureController?
    private var displayLink: CADisplayLink?

    // Latest reading pushed in from AppState. Read by the render loop.
    private var noteLabel: String?
    private var targetCents: Double = 0
    private var displayCents: Double = 0
    private var frequency: Double = 0
    private var isStable: Bool = false
    private var pitchHistory: [PIPPitchSample] = []
    private var lastHistorySampleTime: CFTimeInterval = 0
    private var metronomeState: MetronomeEngine.PlaybackState? = nil
    /// MIDI note + readable label of the drone, when one is playing.
    /// Both `nil` when no drone — the view collapses its row.
    private var droneMidi: Int? = nil
    private var droneLabel: String? = nil
    /// Latest tuning-preset snapshot. The PIP view shows a compact
    /// E A D G B E strings row beneath the strobe whenever a non-
    /// chromatic preset is active. `labels.isEmpty` = chromatic =
    /// no row drawn. `activeIndex` highlights the string closest
    /// to the user's current pitch.
    private var presetLabels: [String] = []
    private var presetActiveIndex: Int? = nil
    private var presetTunedIndices: Set<Int> = []
    private let stateQueue = DispatchQueue(label: "ttuner.pip.state")

    /// Time-to-live for a pitch dot — defines how long it takes to
    /// rise from the bottom of the history rail to the top before
    /// fading out.
    static let historyMaxAge: CFTimeInterval = 3.0
    /// Minimum gap between history samples (≈12 Hz). Keeps the rail
    /// readable instead of solid-line dense at full pitch-detector rate.
    private let historySampleInterval: CFTimeInterval = 0.08
    /// Per-frame easing toward the latest cents reading. Small enough
    /// to be "subtle smoothing", large enough that the needle still
    /// tracks fast intonation changes within a few frames.
    private let centsSmoothing: Double = 0.30

    private let renderSize = TunerPIPView.renderSize
    /// Render at 3× point density so the upscaled PIP window looks
    /// crisp on Retina screens. The 9× pixel cost is fine at 12 fps.
    private let renderScale: CGFloat = 3

    override init() {
        super.init()
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.backgroundColor = UIColor.black.cgColor
    }

    // MARK: - Setup

    /// Attach the sample-buffer layer to a host view and prime the PIP
    /// controller for auto-start when the app backgrounds. The host
    /// view is expected to be a small near-invisible overlay in the
    /// main window — its only job is to satisfy iOS's "source layer
    /// must be on-screen" rule. Idempotent.
    func attach(to host: UIView) {
        NSLog("[PIP] attach entered, pip=\(pip == nil ? "nil" : "exists"), host=\(host)")
        guard pip == nil else { return }
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        NSLog("[PIP] attach — supported=\(supported), host.bounds=\(host.bounds)")
        guard supported else { return }

        sampleBufferLayer.frame = host.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 80, height: 50)
            : host.bounds
        host.layer.addSublayer(sampleBufferLayer)

        // If the decoder/renderer ever lands in `.failed`, the layer
        // stops accepting buffers and the PIP window stays black until
        // we flush it. The KVO observer catches that automatically so
        // the user doesn't have to relaunch the app.
        sampleBufferLayer.addObserver(self,
                                       forKeyPath: "status",
                                       options: [.new],
                                       context: nil)

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller

        // Watch the system's eligibility flag so we know when PIP becomes
        // usable. KVO is required because Apple updates the flag from
        // internal state changes the app can't otherwise observe.
        pip?.addObserver(self,
                         forKeyPath: "pictureInPicturePossible",
                         options: [.new, .initial],
                         context: nil)

        startRenderLoop()
        NSLog("[PIP] controller created, render loop started")
    }

    override func observeValue(forKeyPath keyPath: String?,
                                of object: Any?,
                                change: [NSKeyValueChangeKey : Any]?,
                                context: UnsafeMutableRawPointer?) {
        if keyPath == "pictureInPicturePossible" {
            let possible = (change?[.newKey] as? Bool) ?? false
            NSLog("[PIP] isPictureInPicturePossible → \(possible)")
        } else if keyPath == "status",
                  let layer = object as? AVSampleBufferDisplayLayer {
            if layer.status == .failed {
                NSLog("[PIP] sampleBufferLayer failed: \(layer.error?.localizedDescription ?? "unknown") — flushing")
                layer.flush()
            }
        }
    }

    // MARK: - Data input

    /// Called by AppState when a new tuner reading lands. Safe to call
    /// from any thread.
    func updateReading(noteLabel: String?, cents: Double, frequency: Double, isStable: Bool) {
        let now = CACurrentMediaTime()
        stateQueue.sync {
            self.noteLabel = noteLabel
            self.targetCents = cents
            self.frequency = frequency
            self.isStable = isStable
            // Accumulate a sparse pitch trace so the PIP can show where
            // the user has been over the last few seconds, not just
            // where they are right now.
            if noteLabel != nil,
               now - self.lastHistorySampleTime >= self.historySampleInterval {
                self.pitchHistory.append(PIPPitchSample(time: now, cents: cents))
                self.lastHistorySampleTime = now
                // Single-pass prune. The previous `while removeFirst()`
                // loop was O(n²) because every removal shifted the tail
                // — fine for ~37 samples but pointless when one pass
                // does the same work in O(n).
                let cutoff = now - Self.historyMaxAge
                self.pitchHistory.removeAll { $0.time < cutoff }
            }
        }
    }

    /// Mirror of `AppState.metronomePlaybackState`. The PIP view uses
    /// `barStartDate` + `bpm` to animate its own beat dots without
    /// per-beat pushes.
    func updateMetronome(_ state: MetronomeEngine.PlaybackState?) {
        stateQueue.sync {
            self.metronomeState = state
        }
    }

    /// Tell PIP about the currently-playing drone. `midi: nil` means no
    /// drone — the indicator collapses. `label` is the human-readable
    /// note name (e.g. "A4") computed in `AppState` where transpose /
    /// notation preferences live.
    func updateDrone(midi: Int?, label: String?) {
        stateQueue.sync {
            self.droneMidi = midi
            self.droneLabel = label
        }
    }

    /// Push the active tuning preset's per-string state into PIP so it
    /// can draw a compact strings row beneath the strobe. Pass empty
    /// `labels` for chromatic mode.
    func updatePreset(labels: [String], activeIndex: Int?, tunedIndices: Set<Int>) {
        stateQueue.sync {
            self.presetLabels = labels
            self.presetActiveIndex = activeIndex
            self.presetTunedIndices = tunedIndices
        }
    }

    // MARK: - Manual control

    /// True once the system has decided PIP is ready to start. The UI
    /// button observes this to enable/disable the "Pin" affordance.
    /// `isPictureInPicturePossible` becomes true some time after attach
    /// — typically once the first sample buffer has been enqueued and
    /// the audio session is active.
    var canStartManually: Bool {
        pip?.isPictureInPicturePossible == true
    }

    /// Start PIP now. Must be called while the app is foreground/active
    /// (iOS rejects the call from a background state). Idempotent — if
    /// already in PIP, the call no-ops.
    func startManually() {
        guard let pip else {
            NSLog("[PIP] startManually before attach")
            return
        }
        let session = AVAudioSession.sharedInstance()
        NSLog("""
              [PIP] startManually \
              isPossible=\(pip.isPictureInPicturePossible) \
              isActive=\(pip.isPictureInPictureActive) \
              audioCategory=\(session.category.rawValue) \
              audioActive=\(session.isOtherAudioPlaying ? "otherPlaying" : "self") \
              outputs=\(session.currentRoute.outputs.map { $0.portType.rawValue })
              """)
        // Try anyway — sometimes isPictureInPicturePossible lags by a
        // frame even when the system is ready to start. The delegate's
        // failedToStart callback will log if it really can't.
        pip.startPictureInPicture()
    }

    func stopManually() {
        pip?.stopPictureInPicture()
    }

    // MARK: - Render loop

    private func startRenderLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        // 30 fps so the needle's smoothed easing reads as actual motion
        // rather than discrete steps. Frame cost is fine — even at 3×
        // render scale it's ~150 µs per frame on modern iPhones.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRenderLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func renderTick() {
        // CADisplayLink fires on the runloop we attached to (`.main`),
        // so we are on the main thread — but the compiler can't infer
        // MainActor isolation through the `@objc` selector hop. We
        // assume it explicitly so `ImageRenderer` (MainActor-isolated)
        // is callable here without an `await`.
        MainActor.assumeIsolated { renderAndEnqueue() }
    }

    @MainActor
    private func renderAndEnqueue() {
        let snapshot: (note: String?,
                       target: Double,
                       freq: Double,
                       stable: Bool,
                       history: [PIPPitchSample],
                       metronome: MetronomeEngine.PlaybackState?,
                       droneLabel: String?,
                       presetLabels: [String],
                       presetActive: Int?,
                       presetTuned: Set<Int>) =
            stateQueue.sync { (noteLabel, targetCents, frequency, isStable,
                                pitchHistory, metronomeState,
                                droneLabel, presetLabels, presetActiveIndex,
                                presetTunedIndices) }
        // Subtle easing on cents so the needle glides instead of
        // jumping each pitch-detector frame.
        displayCents += (snapshot.target - displayCents) * centsSmoothing

        let now = CACurrentMediaTime()
        guard let pixelBuffer = renderFrame(noteLabel: snapshot.note,
                                            cents: displayCents,
                                            frequency: snapshot.freq,
                                            isStable: snapshot.stable,
                                            history: snapshot.history,
                                            renderTime: now,
                                            metronome: snapshot.metronome,
                                            droneLabel: snapshot.droneLabel,
                                            presetLabels: snapshot.presetLabels,
                                            presetActive: snapshot.presetActive,
                                            presetTuned: snapshot.presetTuned),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else {
            return
        }
        sampleBufferLayer.enqueue(sampleBuffer)
    }

    @MainActor
    private func renderFrame(noteLabel: String?,
                             cents: Double,
                             frequency: Double,
                             isStable: Bool,
                             history: [PIPPitchSample],
                             renderTime: CFTimeInterval,
                             metronome: MetronomeEngine.PlaybackState?,
                             droneLabel: String?,
                             presetLabels: [String],
                             presetActive: Int?,
                             presetTuned: Set<Int>) -> CVPixelBuffer? {
        let view = TunerPIPView(noteLabel: noteLabel,
                                cents: cents,
                                frequency: frequency,
                                isStable: isStable,
                                history: history,
                                renderTime: renderTime,
                                metronome: metronome,
                                droneLabel: droneLabel,
                                presetLabels: presetLabels,
                                presetActiveIndex: presetActive,
                                presetTunedIndices: presetTuned)
        let renderer = ImageRenderer(content: view)
        renderer.scale = renderScale
        renderer.proposedSize = ProposedViewSize(width: renderSize.width,
                                                  height: renderSize.height)
        guard let cgImage = renderer.cgImage else { return nil }
        let pixelSize = CGSize(width: renderSize.width * renderScale,
                               height: renderSize.height * renderScale)
        return makePixelBuffer(from: cgImage, size: pixelSize)
    }

    private func makePixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          attrs,
                                          &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let fmt = formatDescription else { return nil }

        let presentationTime = CMTime(seconds: CACurrentMediaTime(),
                                      preferredTimescale: 60_000)
        // `.invalid` duration means "display this until replaced" rather
        // than "display this for exactly 33 ms". Without it, a single
        // skipped render tick (background scheduling, ImageRenderer
        // hiccup) lets the previous frame's PTS expire and the
        // AVSampleBufferDisplayLayer falls back to black — the state
        // the user reports getting stuck in.
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - Playback delegate (mandatory protocol stubs)
//
// Custom-content PIP reuses the video-playback delegate API. The system
// expects a `setPlaying` / `isPaused` / `skip` shape because it normally
// drives an underlying media player. We don't have one — we just claim
// to be "live", "never paused", and ignore skip requests so the system's
// scrubber chrome doesn't appear or do anything.

extension TunerPIPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     setPlaying playing: Bool) {
        // Our "playback" is just the live tuner — pause is a no-op.
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // `negativeInfinity..<positiveInfinity` tells the system this is
        // an open-ended live stream, which hides the scrubber.
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // No-op: we render at our own fixed resolution and let the
        // system scale to whatever the user has dragged the window to.
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     skipByInterval skipInterval: CMTime,
                                     completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - Lifecycle delegate

extension TunerPIPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PIP] willStart")
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PIP] didStart")
    }
    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PIP] willStop")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PIP] didStop")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                     failedToStartPictureInPictureWithError error: any Error) {
        NSLog("[PIP] failedToStart: \(error)")
    }
}

// MARK: - SwiftUI bridge
//
// A nearly-invisible 80×50 view that the app plants in its window's
// view hierarchy. iOS uses its on-screen presence as proof that the
// PIP source is "inline" and therefore eligible for auto-start when
// the user backgrounds the app.

/// UIView subclass whose only job is to keep its hosted CALayer
/// sized to its own bounds across any layout pass (rotation, scene
/// resize, etc.).
final class PIPHostUIView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
}

struct PIPAttachmentView: UIViewRepresentable {
    func makeUIView(context: Context) -> PIPHostUIView {
        NSLog("[PIP] PIPAttachmentView.makeUIView called")
        let view = PIPHostUIView(frame: CGRect(x: 0, y: 0, width: 80, height: 50))
        view.alpha = 1.0
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        TunerPIPController.shared.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PIPHostUIView, context: Context) {}
}
