import Foundation
import AVFoundation
import QuartzCore
import Observation

/// Metronome scheduler + audio playback.
///
/// Playback is intentionally driven by `AVAudioPlayer`, not the shared
/// `AVAudioEngine` that `CaptureEngine` owns. This used to crash and/or
/// silently fail to route audio whenever both clients tried to mutate
/// the same engine graph; the AVAudioPlayer path is entirely independent
/// and "just works" alongside the recording tap.
///
/// Each beat instantiates a fresh one-shot `AVAudioPlayer` backed by a
/// cached in-memory WAV blob. `play(atTime: deviceCurrentTime + delay)`
/// gives sample-precise scheduling without any sample-time arithmetic.
@Observable
final class MetronomeEngine {
    // Public state
    private(set) var isPlaying: Bool = false
    var bpm: Double = 120 {
        didSet {
            if isPlaying {
                rebuildSchedule()
                emitState()
            }
        }
    }
    var timeSignature: TimeSignature = .fourFour {
        didSet {
            ensureAccentLength()
            if isPlaying {
                rebuildSchedule()
                emitState()
            }
        }
    }
    var accentPattern: [Accent] = TimeSignature.defaultAccentPattern(for: .fourFour) {
        didSet {
            rebuildClickCacheIfNeeded()
            if isPlaying { emitState() }
        }
    }
    var tone: String = "wood"
    var btLatencyCompensation: Bool = true

    // Mode + advanced options
    var mode: MetronomeMode = .simple { didSet { if isPlaying { rebuildSchedule() } } }
    /// How many bars of count-in to play before the actual cycle. 0 disables.
    var countInBars: Int = 0
    /// 1 = off. 2/3/4 split each beat. Visual-only by default.
    var subdivision: Int = 1
    /// Whether subdivisions also produce a soft audible tick.
    var subdivisionAudible: Bool = false

    /// Indicates that the scheduler is currently in count-in lead-in.
    private(set) var inCountIn: Bool = false

    /// Latest BPM the scheduler is actually using right now. While the
    /// metronome is stopped this lags behind whatever fresh value
    /// `displayBPM` would compute; consult `displayBPM` for UI.
    private(set) var currentEffectiveBPM: Double = 120

    /// What the UI should show as "the current BPM". Tracks
    /// `currentEffectiveBPM` during playback (so Speed Trainer's
    /// climb is reflected live) and falls back to the base / start
    /// value when stopped.
    var displayBPM: Double {
        if isPlaying { return currentEffectiveBPM }
        if case .speedTrainer(let start, _, _) = mode { return start }
        return bpm
    }

    // Observed beat marker queue
    private(set) var markers: [BeatMarker] = []
    private let markersMax = 192

    // Audio — WAV blobs cached per accent. Each beat spins up a one-shot
    // AVAudioPlayer; activePlayers retains them until they've finished.
    private static let renderSampleRate: Double = 48_000
    private var clickWavData: [Accent: Data] = [:]
    private var subdivClickWav: Data?
    private var activePlayers: [AVAudioPlayer] = []

    // Scheduling
    private var primaryBeatIndex: Int = 0
    private var beatsScheduled: Int = 0
    /// Wall-clock time at which the *next* primary beat should fire.
    private var nextBeatWallTime: TimeInterval = 0
    /// Visual markers spend this long approaching the flame before their
    /// audio fires. Audio itself is scheduled via `play(atTime:)` so its
    /// actual fire time is sample-precise regardless of this lookahead.
    private let lookAheadSeconds: Double = 1.6
    private let scheduleQueue = DispatchQueue(label: "ttuner.metronome.schedule")
    private var timer: DispatchSourceTimer?

    var onScheduleMarker: ((BeatMarker) -> Void)?

    /// Fired whenever the metronome's externally-visible playback state
    /// changes: start, stop, BPM change, time-signature change, accent
    /// pattern change. The payload encodes everything the Live Activity
    /// needs to render and self-animate indefinitely — it deliberately
    /// does *not* fire per-beat (that would re-introduce the update
    /// storm that drove Live Activities into iOS throttling).
    /// `nil` means "stopped"; the coordinator uses that as its end
    /// signal.
    var onMetronomeState: ((PlaybackState?) -> Void)?

    init() {
        ensureAccentLength()
        rebuildClickCacheIfNeeded(force: true)
    }

    /// Snapshot the metronome reports whenever its public playback
    /// shape changes. `barStartDate` is the wall-clock time of the
    /// current bar's beat 0 — extrapolating forward by `60/bpm`
    /// seconds gives every subsequent beat, which is what lets the
    /// Live Activity widget self-tick via TimelineView.
    struct PlaybackState {
        let bpm: Double
        let beatsPerBar: Int
        let accents: [Bool]
        let barStartDate: Date
    }

    deinit {
        stop()
    }

    /// No-op kept for backwards compatibility with `AppState.startEngines()`.
    /// Metronome audio no longer needs the shared AVAudioEngine.
    func configureGraph() {}

    private func ensureAccentLength() {
        let n = max(1, timeSignature.numerator)
        if accentPattern.count < n {
            accentPattern.append(contentsOf: Array(repeating: Accent.normal, count: n - accentPattern.count))
        } else if accentPattern.count > n {
            accentPattern = Array(accentPattern.prefix(n))
        }
    }

    private func rebuildClickCacheIfNeeded(force: Bool = false) {
        if !force && !clickWavData.isEmpty { return }
        clickWavData.removeAll()
        for a in [Accent.soft, .normal, .accent] {
            if let d = ClickSoundFactory.wavData(sampleRate: Self.renderSampleRate, accent: a, tone: tone) {
                clickWavData[a] = d
            }
        }
        subdivClickWav = ClickSoundFactory.wavData(sampleRate: Self.renderSampleRate, accent: .soft, tone: "subtle")
    }

    // MARK: - Transport

    func start() {
        guard !isPlaying else { return }
        markers.removeAll(keepingCapacity: true)
        primaryBeatIndex = 0
        beatsScheduled = 0
        inCountIn = countInBars > 0
        // First beat lands a comfortable distance in the future so the
        // visual marker has time to scroll into view before audio fires.
        nextBeatWallTime = CACurrentMediaTime() + 0.15
        // Seed the effective BPM with what the first real beat will
        // actually use, so the display doesn't briefly show a stale
        // value before tick() schedules anything.
        if case .speedTrainer(let s, _, _) = mode {
            currentEffectiveBPM = s
        } else {
            currentEffectiveBPM = bpm
        }
        isPlaying = true
        emitState()

        let t = DispatchSource.makeTimerSource(queue: scheduleQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Fire a single click immediately. Used by the accent bar buttons so
    /// the user can audition the chosen strength.
    func previewClick(accent: Accent) {
        guard accent != .off, let data = clickWavData[accent] else { return }
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            self.playOneShot(data: data, delay: 0)
        }
    }

    /// Halt the scheduler + audio without touching `markers`. Used when
    /// the user enters scrub mode: the beat lines they were just hearing
    /// should remain on screen so they can inspect them. Resume is via
    /// `start()` which clears markers and restarts the cycle from beat 0.
    func pauseForScrub() {
        guard isPlaying else { return }
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for p in self.activePlayers { p.stop() }
            self.activePlayers.removeAll()
        }
        isPlaying = false
        inCountIn = false
        onMetronomeState?(nil)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            let players = self.activePlayers
            DispatchQueue.main.async {
                for p in players { p.stop() }
                self.activePlayers.removeAll()
            }
        }
        let wasPlaying = isPlaying
        isPlaying = false
        inCountIn = false
        // Drop any visual markers already in the lookahead window so they
        // don't keep crossing the flame after stop. Re-use onScheduleMarker
        // as a "markers changed" ping — the ContentView handler re-reads
        // metronome.markers and ignores the marker argument.
        markers.removeAll(keepingCapacity: true)
        onScheduleMarker?(BeatMarker(hostTime: 0, accent: .off, trackId: 0, bpm: 0))
        if wasPlaying { onMetronomeState?(nil) }
    }

    private func rebuildSchedule() {
        // Cancel everything we'd queued at the OLD tempo — both audible
        // clicks already scheduled in the lookahead window and the
        // visual markers approaching the flame. Without this, the new
        // tempo plays *on top of* the old one for up to one lookahead
        // window (≈1.6 s), which sounds like double-beating.
        //
        // activePlayers is mutated by playOneShot's main-queue async
        // append, so do the teardown on main to stay race-free.
        let cancelInFlight = { [weak self] in
            guard let self else { return }
            for p in self.activePlayers { p.stop() }
            self.activePlayers.removeAll()
            self.markers.removeAll(keepingCapacity: true)
            self.onScheduleMarker?(BeatMarker(hostTime: 0, accent: .off,
                                              trackId: 0, bpm: 0))
        }
        if Thread.isMainThread {
            cancelInFlight()
        } else {
            DispatchQueue.main.async(execute: cancelInFlight)
        }
        // Resume scheduling at the new tempo. Pattern position
        // (primaryBeatIndex) is preserved so the accent cycle doesn't
        // jump to the downbeat just because BPM changed.
        nextBeatWallTime = CACurrentMediaTime() + 0.08
        beatsScheduled = 0
    }

    // MARK: - Scheduling

    private func tick() {
        guard isPlaying else { return }
        let now = CACurrentMediaTime()
        let horizon = now + lookAheadSeconds
        let numerator = max(1, timeSignature.numerator)

        while nextBeatWallTime < horizon {
            let totalBeats = primaryBeatIndex
            let inLeadIn = totalBeats < countInBars * numerator
            inCountIn = inLeadIn

            let cycleBeat = inLeadIn
                ? (totalBeats % numerator)
                : ((totalBeats - countInBars * numerator) % numerator)
            let patternAccent = accentPattern[cycleBeat % numerator]
            let currentBPM = computeCurrentBPM(beatsScheduled: beatsScheduled, inCountIn: inLeadIn)
            let secondsPerBeat = 60.0 / max(1, currentBPM)

            // Push the new BPM to the published display value once it
            // actually shifts — Speed Trainer steps the tempo upward
            // every N bars, and we want the readout to track that.
            // 0.5 BPM threshold suppresses any float rounding noise.
            // Re-emit playback state alongside so the chip / PIP can
            // rebase their TimelineView animations to the new tempo.
            if !inLeadIn, abs(currentBPM - currentEffectiveBPM) > 0.5 {
                let snapshot = currentBPM
                DispatchQueue.main.async { [weak self] in
                    self?.currentEffectiveBPM = snapshot
                    self?.emitState()
                }
            }

            // Count-in always plays soft (lower-pitched) regardless of pattern.
            let audibleAccent: Accent = inLeadIn ? .soft : patternAccent
            let trackId: UInt8 = inLeadIn ? BeatTrack.countIn.rawValue : BeatTrack.primary.rawValue
            scheduleBeat(at: nextBeatWallTime,
                         accent: audibleAccent,
                         trackId: trackId,
                         bpm: currentBPM,
                         cycleBeat: cycleBeat,
                         beatsPerBar: numerator,
                         inCountIn: inLeadIn)

            nextBeatWallTime += secondsPerBeat
            primaryBeatIndex += 1
            if !inLeadIn { beatsScheduled += 1 }
        }
    }

    private func scheduleBeat(at wallTime: TimeInterval,
                              accent: Accent,
                              trackId: UInt8,
                              bpm: Double,
                              cycleBeat: Int,
                              beatsPerBar: Int,
                              inCountIn: Bool) {
        // 1. Visual marker — host time corresponds to the audio play moment.
        let hostTime = machHostTime(forWallTime: wallTime)
        let marker = BeatMarker(hostTime: hostTime, accent: accent,
                                trackId: trackId, bpm: bpm)
        DispatchQueue.main.async { [weak self] in self?.append(marker: marker) }

        // 2. Audio — only when the beat is audible. No per-beat Live
        // Activity hook here on purpose: the widget's TimelineView
        // self-animates from `barStartDate` + `bpm`, so we only need to
        // push a state when those values change (start/stop/bpm/
        // timeSig/accent), not on every beat.
        if accent != .off, let data = clickWavData[accent] {
            let delay = max(0, wallTime - CACurrentMediaTime())
            playOneShot(data: data, delay: delay)
        }
    }

    /// Build a one-shot AVAudioPlayer from the cached WAV data, schedule
    /// it for `delay` seconds in the future, and retain it until it has
    /// finished playing. All player ops happen on the main queue so the
    /// activePlayers array stays single-threaded.
    private func playOneShot(data: Data, delay: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let p = try AVAudioPlayer(data: data)
                p.prepareToPlay()
                if delay <= 0.001 {
                    p.play()
                } else {
                    p.play(atTime: p.deviceCurrentTime + delay)
                }
                self.activePlayers.append(p)
                // Release once the click has decayed (~80 ms + buffer).
                let cleanupAfter = max(0.05, delay) + 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + cleanupAfter) { [weak self] in
                    self?.activePlayers.removeAll { $0 === p }
                }
            } catch {
                NSLog("MetronomeEngine playOneShot failed: \(error)")
            }
        }
    }

    private func machHostTime(forWallTime wallTime: TimeInterval) -> UInt64 {
        // CACurrentMediaTime() returns mach_absolute_time() converted to
        // seconds via the host timebase. Invert via the same constant to
        // get back to ticks for BeatMarker.hostTime.
        let secsPerTick = MetronomeEngine.machSecondsPerTick
        return UInt64(wallTime / secsPerTick)
    }

    /// Compute the current bar-start anchor in wall-clock time and emit
    /// the resulting playback state to `onMetronomeState`. The anchor
    /// is `nextBeatWallTime - cycleBeatOfNextBeat * secsPerBeat`, i.e.
    /// the wall time when this bar's beat 0 fired (or will fire if
    /// we're still in the lead-in window). Combined with bpm, the
    /// widget can extrapolate every subsequent beat without us pushing
    /// per-beat updates.
    private func emitState() {
        guard isPlaying else {
            onMetronomeState?(nil)
            return
        }
        let n = max(1, timeSignature.numerator)
        // Use the *effective* BPM (post Speed Trainer / Gradual ramp)
        // so the published period matches what the scheduler is
        // actually playing right now. If we used `bpm` (the base)
        // here, the chip / PIP TimelineView would tick at the wrong
        // rate whenever the active tempo had diverged from the user-
        // configured base.
        let live = max(1, currentEffectiveBPM)
        let secsPerBeat = 60.0 / live
        let totalBeats = primaryBeatIndex
        let inLeadIn = totalBeats < countInBars * n
        let cycleBeat = inLeadIn
            ? (totalBeats % n)
            : ((totalBeats - countInBars * n) % n)
        let barStartMedia = nextBeatWallTime - secsPerBeat * Double(cycleBeat)
        let barStartDate = Date(timeIntervalSinceNow: barStartMedia - CACurrentMediaTime())
        let accents = accentPattern.prefix(n).map { $0 == .accent }
        let state = PlaybackState(
            bpm: live,
            beatsPerBar: n,
            accents: Array(accents),
            barStartDate: barStartDate
        )
        onMetronomeState?(state)
    }

    private static let machSecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) * 1e-9
    }()

    private func computeCurrentBPM(beatsScheduled: Int, inCountIn: Bool) -> Double {
        if inCountIn { return bpm }
        if case .gradual(let s, let e, let bars) = mode {
            let totalBeats = max(1, bars * timeSignature.numerator)
            let t = min(1.0, Double(beatsScheduled) / Double(totalBeats))
            return s + (e - s) * t
        }
        if case .speedTrainer(let start, let end, let bps) = mode {
            let beatsPerStep = max(1, bps) * timeSignature.numerator
            let steps = beatsScheduled / beatsPerStep
            // Fixed +5 BPM per step. Clamp at end so the trainer holds
            // the target tempo rather than running past it.
            let raw = start + Double(steps) * 5
            return end >= start ? min(end, raw) : max(end, raw)
        }
        return bpm
    }

    private func append(marker: BeatMarker) {
        markers.append(marker)
        if markers.count > markersMax {
            markers.removeFirst(markers.count - markersMax)
        }
        onScheduleMarker?(marker)
    }

    // MARK: - Tap tempo
    private var tapTimes: [TimeInterval] = []
    func registerTap(now: TimeInterval = CACurrentMediaTime()) {
        // Reset the buffer after a long pause — a new attempt deserves
        // a fresh history.
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst(tapTimes.count - 8) }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes, tapTimes.dropFirst()).map { $1 - $0 }

        // The original code used the raw median. With 3–5 taps a single
        // sticky tap (e.g., 250 ms when the rest are 500 ms) skews the
        // median sample enough to feel "wrong". Better: take the median
        // as a reference, drop intervals that are off by more than ±50 %
        // from it, and average the rest. That keeps the algorithm robust
        // to outliers while putting more weight on the user's intent.
        let sortedIntervals = intervals.sorted()
        let medianRef = sortedIntervals[sortedIntervals.count / 2]
        let kept = intervals.filter { $0 >= medianRef * 0.6 && $0 <= medianRef * 1.7 }
        guard !kept.isEmpty else { return }
        let mean = kept.reduce(0, +) / Double(kept.count)
        guard mean > 0 else { return }

        let raw = 60.0 / mean
        var n = raw
        while n < 40 { n *= 2 }
        while n > 240 { n /= 2 }
        bpm = (n * 10).rounded() / 10
    }

    /// Fade-out helper retained for callers that want a soft stop instead
    /// of an abrupt one. Audio decays naturally because AVAudioPlayer has
    /// its own .volume property; we ramp activePlayers' volume to zero.
    func fadeOut(duration: TimeInterval = 0.3) {
        guard isPlaying else { return }
        let steps = 12
        let interval = duration / Double(steps)
        for s in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(s)) { [weak self] in
                guard let self else { return }
                let frac = Float(s) / Float(steps)
                for p in self.activePlayers { p.volume = 1.0 - frac }
                if s == steps { self.stop() }
            }
        }
    }
}
