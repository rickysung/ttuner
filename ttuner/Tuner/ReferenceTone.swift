import AVFoundation
import Foundation

/// On-demand reference-pitch playback. Synthesises a short sine burst
/// (with a touch of 2nd harmonic for warmth and a soft attack/release
/// envelope so it doesn't click) and plays it through `AVAudioPlayer`
/// — the same independent-of-the-shared-engine path the metronome
/// uses, so it never disturbs the capture pipeline.
final class ReferenceTone {
    static let shared = ReferenceTone()

    private var player: AVAudioPlayer?
    private let sampleRate: Double = 48_000
    private let toneDuration: Double = 1.2

    private init() {}

    /// Play the reference tone for a MIDI note. The audible frequency
    /// is derived from the caller's reference A so a user who tuned to
    /// A=442 hears 442-based references, not vanilla 440.
    func play(midi: Int, referenceA: Double = 440) {
        let freq = NoteMapper.frequency(forMidi: midi, referenceA: referenceA)
        guard freq > 0, let data = wavData(frequency: freq) else { return }
        do {
            player?.stop()
            let p = try AVAudioPlayer(data: data)
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            NSLog("ReferenceTone play failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - Synthesis

    private func wavData(frequency: Double) -> Data? {
        let totalFrames = Int(sampleRate * toneDuration)
        guard totalFrames > 0 else { return nil }

        var samples = [Float](repeating: 0, count: totalFrames)
        let twoPi = 2 * Double.pi
        let phaseInc = twoPi * frequency / sampleRate
        var phase = 0.0

        // Linear attack to avoid the speaker pop, slower release so the
        // tone tapers rather than cuts. Sustain in between rides at the
        // chosen peak amplitude.
        let attackFrames = Int(sampleRate * 0.025)
        let releaseFrames = Int(sampleRate * 0.25)
        let sustainEnd = totalFrames - releaseFrames
        // Higher peak — measurement-mode iOS sessions don't apply the
        // usual playback loudness curve, so 0.40 felt timid through
        // device speakers. 0.65 stays safely under the [-1,1] clamp
        // after the 2nd-harmonic adds its 0.15 amplitude on top.
        let peak: Double = 0.65

        for i in 0..<totalFrames {
            var env = peak
            if i < attackFrames {
                env *= Double(i) / Double(attackFrames)
            } else if i >= sustainEnd {
                env *= Double(totalFrames - i) / Double(releaseFrames)
            }
            // Pure sine plus a discreet 2nd-harmonic so the tone has a
            // bit of body — pure sines sound clinical and don't carry
            // well through small speakers.
            let s = sin(phase) + 0.15 * sin(2 * phase)
            samples[i] = Float(s * env)
            phase += phaseInc
            if phase > twoPi { phase -= twoPi }
        }

        return WAVEncoder.makeWAVData(samples: samples, sampleRate: sampleRate)
    }
}
