import Foundation
import QuartzCore

/// Pulls audio from the ring buffer on a high-priority queue, runs FFT and YIN,
/// and emits SpectrumFrame / PitchEvent values to subscribers.
final class AnalysisEngine {
    private let ringBuffer: AudioRingBuffer
    private let hopSize: Int
    private let displayBins: Int
    private let sampleRate: Float

    private let cqt: ConstantQTransform
    private let yin: YINPitchDetector

    private var cqtWindow: [Float]
    private var pitchTempBuffer: [Float]
    private var rebinBuffer: [Float]

    private let queue = DispatchQueue(label: "ttuner.analysis", qos: .userInteractive)
    private var running = false

    // MARK: - Pitch stability filtering
    //
    // Raw YIN output is noisy in real-world signals: a stray glitch
    // can produce a half- or double-frequency outlier every few frames.
    // We pass detections through three gates before emitting:
    //
    //  1. RMS gate — input under `minRmsDb` is treated as silence so
    //     low-level mic noise can't accidentally satisfy YIN's period.
    //  2. Clarity gate — YIN already returns a confidence; we tighten
    //     the cutoff well above the default so only sharp periodic
    //     detections survive.
    //  3. Median-of-3 in semitone space — a single octave-jump outlier
    //     between two consistent readings gets dropped automatically.
    private var f0Buffer: [Float] = []
    private let f0BufferMax = 3
    private let minRmsDb: Float = -45
    private let minClarity: Float = 0.85

    var onSpectrumFrame: ((SpectrumFrame) -> Void)?
    var onPitchEvent: ((PitchEvent?) -> Void)?
    var onRMSUpdate: ((Float) -> Void)?

    /// Power-of-two FFT size used internally by the constant-Q transform.
    /// 32768 at 48 kHz gives a 683 ms window — long enough that the C2 (≈ 65 Hz)
    /// kernel covers its full Q-factor period.
    static let cqtFftSize = 32_768
    /// Number of output (musical) bins. Set so log-uniform spacing across
    /// the configured range works out to ≈ 24 bins per octave.
    static let cqtBinCount = 144
    /// Display range — C2 (lowest contrabass note) up to C8 (above piccolo).
    static let cqtMinHz: Float = 65.4064
    static let cqtMaxHz: Float = 4_186.01

    init(ringBuffer: AudioRingBuffer,
         sampleRate: Float,
         hopSize: Int = 512) {
        self.ringBuffer = ringBuffer
        self.sampleRate = sampleRate
        self.hopSize = hopSize
        self.displayBins = Self.cqtBinCount
        guard let cqt = ConstantQTransform(
            fftSize: Self.cqtFftSize,
            sampleRate: sampleRate,
            minHz: Self.cqtMinHz,
            maxHz: Self.cqtMaxHz,
            totalBins: Self.cqtBinCount
        ) else {
            preconditionFailure("CQT init failed")
        }
        self.cqt = cqt
        self.yin = YINPitchDetector(windowSize: 2048, sampleRate: sampleRate)
        self.cqtWindow = [Float](repeating: 0, count: Self.cqtFftSize)
        self.pitchTempBuffer = [Float](repeating: 0, count: yin.windowSize)
        self.rebinBuffer = [Float](repeating: 0, count: Self.cqtBinCount)
    }

    func start() {
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        running = false
    }

    /// 3-tap median in semitone space. Operating on semitones (not
    /// linear Hz) means an octave-error outlier — exactly the YIN
    /// failure mode we worry about — is rejected by the same median
    /// rule that handles ordinary jitter. Returns the most recent
    /// confident reading as a fallback when the buffer is short.
    private func applyMedianFilter(_ rawF0: Float) -> Float {
        f0Buffer.append(rawF0)
        if f0Buffer.count > f0BufferMax {
            f0Buffer.removeFirst()
        }
        guard f0Buffer.count >= 2 else { return rawF0 }
        let semitones = f0Buffer.map { 12 * log2f($0 / 440) }.sorted()
        let median = semitones[semitones.count / 2]
        return 440 * powf(2, median / 12)
    }

    private func loop() {
        let pitchInterval = hopSize * 2  // ~21ms cadence
        var samplesSinceLastPitch = 0

        while running {
            let avail = ringBuffer.availableToRead
            if avail < hopSize {
                usleep(useconds_t((Double(hopSize) / Double(sampleRate)) * 0.5 * 1_000_000))
                continue
            }

            // Slide the CQT window forward by exactly one hop.
            let shift = cqtWindow.count - hopSize
            if shift > 0 {
                cqtWindow.withUnsafeMutableBufferPointer { wp in
                    let base = wp.baseAddress!
                    memmove(base, base.advanced(by: hopSize), shift * MemoryLayout<Float>.size)
                    let read = ringBuffer.read(into: base.advanced(by: shift), maxCount: hopSize)
                    if read < hopSize {
                        let pad = hopSize - read
                        for i in 0..<pad { (base + shift + read + i).pointee = 0 }
                    }
                }
            }

            samplesSinceLastPitch += hopSize
            let hostNow = mach_absolute_time()

            // Constant-Q transform — emits one dB value per musical band.
            cqtWindow.withUnsafeBufferPointer { wp in
                cqt.process(samples: wp.baseAddress!, into: &rebinBuffer)
            }

            // RMS over a short trailing slice (≈ 43 ms at 48 kHz) so the
            // volume reading tracks current loudness rather than the
            // entire 683 ms CQT window.
            let rmsWindowSize = min(2048, cqtWindow.count)
            let rmsStart = cqtWindow.count - rmsWindowSize
            var rms: Float = 0
            for i in rmsStart..<cqtWindow.count {
                let s = cqtWindow[i]
                rms += s * s
            }
            rms = sqrt(rms / Float(rmsWindowSize))
            let rmsDb = 20 * log10(max(rms, 1e-9))

            let frame = SpectrumFrame(hostTime: hostNow, bins: rebinBuffer, rmsDb: rmsDb)
            onSpectrumFrame?(frame)
            onRMSUpdate?(rmsDb)

            if samplesSinceLastPitch >= pitchInterval {
                samplesSinceLastPitch = 0
                // RMS gate first: skip YIN entirely on near-silence,
                // which is both cheaper and prevents the algorithm
                // from latching onto whatever noise floor it finds.
                if rmsDb < minRmsDb {
                    f0Buffer.removeAll(keepingCapacity: true)
                    onPitchEvent?(nil)
                } else {
                    let w = yin.windowSize
                    let take = min(w, cqtWindow.count)
                    let off = cqtWindow.count - take
                    cqtWindow.withUnsafeBufferPointer { fp in
                        pitchTempBuffer.withUnsafeMutableBufferPointer { pp in
                            memcpy(pp.baseAddress!, fp.baseAddress!.advanced(by: off), take * MemoryLayout<Float>.size)
                        }
                    }
                    let result = pitchTempBuffer.withUnsafeBufferPointer { yin.detect(samples: $0.baseAddress!) }
                    if let r = result, r.clarity >= minClarity {
                        let stable = applyMedianFilter(r.f0)
                        onPitchEvent?(PitchEvent(hostTime: hostNow, f0: stable, clarity: r.clarity))
                    } else {
                        f0Buffer.removeAll(keepingCapacity: true)
                        onPitchEvent?(nil)
                    }
                }
            }
        }
    }
}
