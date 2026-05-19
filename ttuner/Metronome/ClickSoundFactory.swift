import Foundation
import AVFoundation

/// Synthesizes simple, percussive click buffers (no asset bundle required).
/// Each click is an exponentially-decaying sine burst plus a small white-noise transient.
enum ClickSoundFactory {

    /// In-memory WAV file containing the click. Used to feed
    /// `AVAudioPlayer(data:)` so the metronome runs entirely outside the
    /// AVAudioEngine that CaptureEngine owns — no graph-sharing pitfalls.
    static func wavData(sampleRate: Double, accent: Accent, tone: String) -> Data? {
        guard accent != .off else { return nil }
        let samples = synthesize(sampleRate: sampleRate, accent: accent, tone: tone)
        return wrapPCM16(samples: samples, sampleRate: sampleRate)
    }

    static func buffer(sampleRate: Double, accent: Accent, tone: String) -> AVAudioPCMBuffer? {
        guard accent != .off else { return nil }
        let length = AVAudioFrameCount(sampleRate * 0.08)  // 80ms
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return nil }
        buf.frameLength = length
        let basePitch: Double
        let gain: Float
        switch accent {
        case .accent: basePitch = 1800; gain = 0.95
        case .normal: basePitch = 1200; gain = 0.65
        case .soft:   basePitch = 900;  gain = 0.35
        case .off:    return nil
        }
        let decay: Double = {
            switch tone {
            case "wood":   return 38
            case "click":  return 60
            case "beep":   return 18
            case "subtle": return 80
            default:       return 38
            }
        }()

        let ptr = buf.floatChannelData![0]
        let samples = synthesize(sampleRate: sampleRate, accent: accent, tone: tone)
        for i in 0..<min(samples.count, Int(length)) {
            ptr[i] = samples[i]
        }
        return buf
    }

    /// Render the actual sample stream — same DSP for both the in-memory
    /// PCM buffer (legacy path) and the WAV-wrapped AVAudioPlayer path.
    private static func synthesize(sampleRate: Double, accent: Accent, tone: String) -> [Float] {
        let length = Int(sampleRate * 0.08)  // 80 ms
        let basePitch: Double
        let gain: Float
        // Bumped from 0.95 / 0.65 / 0.35 because session `.measurement`
        // mode disables iOS's output loudness processing, making the
        // metronome quieter than typical system sounds. The wrap step
        // clamps to ±1.0 so the transient peaks of `.accent` clip
        // gently — that actually gives the click extra snap.
        switch accent {
        case .accent: basePitch = 1800; gain = 1.50
        case .normal: basePitch = 1200; gain = 1.10
        case .soft:   basePitch = 900;  gain = 0.70
        case .off:    return []
        }
        let decay: Double = {
            switch tone {
            case "wood":   return 38
            case "click":  return 60
            case "beep":   return 18
            case "subtle": return 80
            default:       return 38
            }
        }()
        var rng = SystemRandomNumberGenerator()
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / sampleRate
            let env = Float(exp(-decay * t))
            let osc = Float(sin(2 * .pi * basePitch * t))
            let noise: Float = (t < 0.004) ? (Float.random(in: -1...1, using: &rng) * 0.4) : 0
            out[i] = gain * env * (osc * 0.85 + noise)
        }
        return out
    }

    /// Pack a Float32 sample array into a 16-bit PCM WAV `Data` blob so
    /// it can be handed directly to `AVAudioPlayer(data:)`.
    private static func wrapPCM16(samples: [Float], sampleRate: Double) -> Data {
        let sr = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let dataBytes = UInt32(samples.count) * UInt32(bytesPerSample)
        let byteRate = sr * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(Int(44 + dataBytes))

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36) + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))           // PCM fmt chunk size
        appendLE(UInt16(1))            // format = PCM
        appendLE(channels)
        appendLE(sr)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        appendLE(dataBytes)

        for f in samples {
            // Clamp + scale to int16. The synthesized waveform peaks
            // around ±1 so we use the full Int16 range.
            let clamped = max(-1, min(1, f))
            let scaled = Int16(clamped * 32767)
            appendLE(scaled)
        }
        return data
    }
}
