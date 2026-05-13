import Foundation
import QuartzCore

/// Pulls audio from the ring buffer on a high-priority queue, runs FFT and YIN,
/// and emits SpectrumFrame / PitchEvent values to subscribers.
final class AnalysisEngine {
    private let ringBuffer: AudioRingBuffer
    private let fftSize: Int
    private let hopSize: Int
    private let displayBins: Int
    private let sampleRate: Float

    private let fft: FFTProcessor
    private let yin: YINPitchDetector
    private let binner: LogBinner

    private var fftWindow: [Float]
    private var pitchWindow: [Float]
    private var pitchTempBuffer: [Float]
    private var rebinBuffer: [Float]

    private let queue = DispatchQueue(label: "ttuner.analysis", qos: .userInteractive)
    private var running = false

    var onSpectrumFrame: ((SpectrumFrame) -> Void)?
    var onPitchEvent: ((PitchEvent?) -> Void)?
    var onRMSUpdate: ((Float) -> Void)?

    init(ringBuffer: AudioRingBuffer,
         sampleRate: Float,
         fftSize: Int = 4096,
         hopSize: Int = 512,
         displayBins: Int = 512,
         minHz: Float = 50,
         maxHz: Float = 20_000) {
        self.ringBuffer = ringBuffer
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.displayBins = displayBins
        self.fft = FFTProcessor(size: fftSize)!
        self.yin = YINPitchDetector(windowSize: 2048, sampleRate: sampleRate)
        self.binner = LogBinner(
            inputBins: fftSize / 2,
            outputBins: displayBins,
            sampleRate: sampleRate,
            minHz: minHz,
            maxHz: min(sampleRate / 2, maxHz)
        )
        self.fftWindow = [Float](repeating: 0, count: fftSize)
        self.pitchWindow = [Float](repeating: 0, count: yin.windowSize)
        self.pitchTempBuffer = [Float](repeating: 0, count: yin.windowSize)
        self.rebinBuffer = [Float](repeating: 0, count: displayBins)
    }

    func start() {
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        running = false
    }

    private func loop() {
        var samplesSinceLastHop = 0
        let pitchInterval = hopSize * 2  // ~21ms cadence
        var samplesSinceLastPitch = 0

        while running {
            let avail = ringBuffer.availableToRead
            if avail < hopSize {
                // Sleep half a hop; reasonable balance between latency and CPU
                usleep(useconds_t((Double(hopSize) / Double(sampleRate)) * 0.5 * 1_000_000))
                continue
            }

            // Consume one hop into a sliding window: shift left by hopSize, fill tail.
            let shift = fftWindow.count - hopSize
            if shift > 0 {
                fftWindow.withUnsafeMutableBufferPointer { wp in
                    let base = wp.baseAddress!
                    memmove(base, base.advanced(by: hopSize), shift * MemoryLayout<Float>.size)
                    let read = ringBuffer.read(into: base.advanced(by: shift), maxCount: hopSize)
                    if read < hopSize {
                        let pad = hopSize - read
                        for i in 0..<pad { (base + shift + read + i).pointee = 0 }
                    }
                }
            }

            samplesSinceLastHop += hopSize
            samplesSinceLastPitch += hopSize

            let hostNow = mach_absolute_time()

            // FFT
            let db = fftWindow.withUnsafeBufferPointer { fft.process(samples: $0.baseAddress!) }

            // Rebin to display bins (log-scale)
            binner.rebin(db, into: &rebinBuffer)
            let frame = SpectrumFrame(hostTime: hostNow, bins: rebinBuffer)
            onSpectrumFrame?(frame)

            // RMS (loudness glow / silence detection)
            var rms: Float = 0
            for v in fftWindow { rms += v * v }
            rms = sqrt(rms / Float(fftWindow.count))
            let rmsDb = 20 * log10(max(rms, 1e-9))
            onRMSUpdate?(rmsDb)

            // YIN (every ~21ms)
            if samplesSinceLastPitch >= pitchInterval {
                samplesSinceLastPitch = 0
                let w = yin.windowSize
                let take = min(w, fftWindow.count)
                let off = fftWindow.count - take
                fftWindow.withUnsafeBufferPointer { fp in
                    pitchTempBuffer.withUnsafeMutableBufferPointer { pp in
                        memcpy(pp.baseAddress!, fp.baseAddress!.advanced(by: off), take * MemoryLayout<Float>.size)
                    }
                }
                let result = pitchTempBuffer.withUnsafeBufferPointer { yin.detect(samples: $0.baseAddress!) }
                if let r = result {
                    onPitchEvent?(PitchEvent(hostTime: hostNow, f0: r.f0, clarity: r.clarity))
                } else {
                    onPitchEvent?(nil)
                }
            }
        }
    }
}
