import AVFoundation
import Foundation
import Observation

/// Sustained reference-pitch playback. Where `ReferenceTone` fires a
/// 1.2-second envelope-shaped burst on tap, `DroneEngine` loops a
/// phase-continuous sine forever until the user stops it, with soft
/// fade-in/out at the boundaries so it never pops.
///
/// Audio is independent of the shared capture engine — uses an
/// `AVAudioPlayer` over a synthesised WAV blob, same pattern as the
/// metronome and reference tone. Keeps playing in the background
/// because the app declares `UIBackgroundModes: [audio]`.
///
/// Marked `@Observable` so the drone panel and the PIP overlay both
/// reflect `currentMidi` without callback wiring.
@Observable
final class DroneEngine {
    static let shared = DroneEngine()

    /// MIDI note currently being droned. `nil` means no drone is
    /// playing — the panel uses this to decide between Play and Stop.
    private(set) var currentMidi: Int? = nil

    /// Reference A the running drone was built for. Stored so a settings
    /// change (e.g. 440 → 442) restarts the drone at the new pitch
    /// instead of leaving the user with a slightly stale reference.
    @ObservationIgnored private var currentReferenceA: Double = 440

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTimer: Timer?

    private let sampleRate: Double = 48_000
    /// Lower than `ReferenceTone`'s 0.65 — the drone plays continuously
    /// and a tone that loud gets fatiguing within a minute.
    private let peakAmplitude: Double = 0.45
    private let fadeInSeconds: TimeInterval = 0.15
    private let fadeOutSeconds: TimeInterval = 0.40

    private init() {}

    var isPlaying: Bool { currentMidi != nil }

    /// Start (or switch to) a drone for the given MIDI note. If a drone
    /// is already playing on a different note we cross over with the
    /// same fade so there's no audible click.
    func start(midi: Int, referenceA: Double = 440) {
        let freq = NoteMapper.frequency(forMidi: midi, referenceA: referenceA)
        guard freq > 20, freq < 8_000, let data = wavData(frequency: freq) else { return }
        stopImmediately()
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            p.setVolume(Float(peakAmplitude), fadeDuration: fadeInSeconds)
            self.player = p
            self.currentMidi = midi
            self.currentReferenceA = referenceA
        } catch {
            NSLog("DroneEngine start failed: \(error)")
        }
    }

    /// Soft-stop: fade volume to zero, then release the player on a
    /// timer matching the fade duration. UI updates immediately (the
    /// note is no longer "current") so the user sees their action
    /// register, but the audio tapers rather than cutting.
    func stop() {
        guard let p = player else {
            currentMidi = nil
            return
        }
        p.setVolume(0, fadeDuration: fadeOutSeconds)
        currentMidi = nil
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: fadeOutSeconds + 0.05,
                                          repeats: false) { [weak self] _ in
            self?.stopImmediately()
        }
    }

    /// Hard-stop: tear down player without any fade. Called when
    /// `start()` switches to a new note (the next note's fade-in
    /// covers the discontinuity).
    private func stopImmediately() {
        player?.stop()
        player = nil
        stopTimer?.invalidate()
        stopTimer = nil
    }

    /// Pick a duration that's close to 1 second AND contains a whole
    /// number of sine cycles. Required for a seamless loop — if the
    /// buffer ends mid-cycle, every loop boundary clicks.
    private func wavData(frequency: Double) -> Data? {
        let cycles = max(20.0, (frequency).rounded())
        let frames = Int((cycles / frequency) * sampleRate)
        guard frames > 0 else { return nil }

        var samples = [Float](repeating: 0, count: frames)
        let twoPi = 2 * Double.pi
        let phaseInc = twoPi * frequency / sampleRate
        var phase = 0.0
        for i in 0..<frames {
            // Pure sine — no harmonic added, because over a long
            // sustain even +0.15 of 2nd harmonic gets fatiguing and
            // muddies intonation reference. Drone needs to be clean.
            // Full-scale here; `AVAudioPlayer.volume` is the single
            // place that scales down to `peakAmplitude`.
            samples[i] = Float(sin(phase))
            phase += phaseInc
            if phase > twoPi { phase -= twoPi }
        }
        return WAVEncoder.makeWAVData(samples: samples, sampleRate: sampleRate)
    }
}
