import Foundation
import AVFoundation

/// Captures mic input through AVAudioEngine and forwards mono Float32 PCM into
/// the shared `AudioRingBuffer`. Audio callback does no allocation and no locking
/// beyond the ring buffer's brief unfair-lock window.
final class CaptureEngine {
    let ringBuffer: AudioRingBuffer
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var sampleRate: Double = 48_000
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacity: Int = 0

    init(capacitySeconds: Double = 12) {
        let cap = Int(capacitySeconds * 48_000)
        self.ringBuffer = AudioRingBuffer(capacitySamples: cap)
    }

    deinit {
        scratch?.deallocate()
    }

    func start() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let preferredSR = AVAudioSession.sharedInstance().sampleRate
        self.sampleRate = preferredSR > 0 ? preferredSR : hwFormat.sampleRate
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        self.targetFormat = target
        if hwFormat.sampleRate != sampleRate || hwFormat.channelCount != 1 {
            self.converter = AVAudioConverter(from: hwFormat, to: target!)
        }
        ensureScratch(capacity: 4096)

        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, sourceFormat: hwFormat)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func ensureScratch(capacity: Int) {
        if scratchCapacity >= capacity { return }
        scratch?.deallocate()
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        scratchCapacity = capacity
    }

    private func handle(buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) {
        guard let target = targetFormat else { return }

        if let conv = converter {
            let ratio = target.sampleRate / sourceFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }
            var error: NSError?
            var didProvide = false
            let status = conv.convert(to: outBuffer, error: &error) { _, outStatus in
                if didProvide {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvide = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || status == .endOfStream { return }
            pushMono(outBuffer)
        } else {
            pushMono(buffer)
        }
    }

    private func pushMono(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        if buffer.format.channelCount == 1 {
            ringBuffer.write(chData[0], count: n)
        } else {
            ensureScratch(capacity: n)
            guard let sc = scratch else { return }
            let chCount = Int(buffer.format.channelCount)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chCount { s += chData[c][i] }
                sc[i] = s / Float(chCount)
            }
            ringBuffer.write(sc, count: n)
        }
    }
}
