import Foundation
import AVFoundation

/// Synthesizes simple, percussive click buffers (no asset bundle required).
/// Each click is an exponentially-decaying sine burst plus a small white-noise transient.
enum ClickSoundFactory {

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
        var rng = SystemRandomNumberGenerator()
        for i in 0..<Int(length) {
            let t = Double(i) / sampleRate
            let env = Float(exp(-decay * t))
            let osc = Float(sin(2 * .pi * basePitch * t))
            // Tiny noise transient on the first 4ms
            let noise: Float = (t < 0.004) ? (Float.random(in: -1...1, using: &rng) * 0.4) : 0
            ptr[i] = gain * env * (osc * 0.85 + noise)
        }
        return buf
    }
}
