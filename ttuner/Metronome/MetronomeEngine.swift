import Foundation
import AVFoundation
import QuartzCore
import Observation
import CoreHaptics

@Observable
final class MetronomeEngine {
    // Public state
    private(set) var isPlaying: Bool = false
    var bpm: Double = 120 { didSet { if isPlaying { rebuildSchedule() } } }
    var timeSignature: TimeSignature = .fourFour { didSet { ensureAccentLength(); if isPlaying { rebuildSchedule() } } }
    var accentPattern: [Accent] = TimeSignature.defaultAccentPattern(for: .fourFour) { didSet { rebuildClickCacheIfNeeded() } }
    var tone: String = "wood"
    var hapticOnBeat: Bool = false
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

    // Observed beat marker queue
    private(set) var markers: [BeatMarker] = []
    private let markersMax = 192

    // Engine
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()

    // Click cache: [Accent : buffer]
    private var clickBuffers: [Accent: AVAudioPCMBuffer] = [:]
    private var subdivClickBuffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 44_100

    // Scheduling
    private var primaryNextSampleTime: AVAudioFramePosition = 0
    private var primaryBeatIndex: Int = 0
    private var secondaryNextSampleTime: AVAudioFramePosition = 0
    private var secondaryBeatIndex: Int = 0
    private var countInBeatIndex: Int = 0
    private var beatsScheduled: Int = 0    // total primary beats scheduled since start (excl. count-in)
    private let lookAheadSeconds: Double = 0.5
    private var scheduleQueue = DispatchQueue(label: "ttuner.metronome.schedule")
    private var timer: DispatchSourceTimer?

    var onScheduleMarker: ((BeatMarker) -> Void)?

    // Haptics
    private var hapticEngine: CHHapticEngine?

    init() {
        ensureAccentLength()
    }

    deinit {
        stop()
    }

    private func ensureAccentLength() {
        let n = max(1, timeSignature.numerator)
        if accentPattern.count < n {
            accentPattern.append(contentsOf: Array(repeating: .normal, count: n - accentPattern.count))
        } else if accentPattern.count > n {
            accentPattern = Array(accentPattern.prefix(n))
        }
    }

    private func setupEngine() throws {
        guard !engine.isRunning else { return }
        engine.attach(player)
        engine.attach(mixer)
        let session = AVAudioSession.sharedInstance()
        sampleRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        engine.connect(player, to: mixer, format: fmt)
        engine.connect(mixer, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        rebuildClickCacheIfNeeded(force: true)
    }

    private func rebuildClickCacheIfNeeded(force: Bool = false) {
        if !force && !clickBuffers.isEmpty { return }
        clickBuffers.removeAll()
        for a in [Accent.soft, .normal, .accent] {
            if let b = ClickSoundFactory.buffer(sampleRate: sampleRate, accent: a, tone: tone) {
                clickBuffers[a] = b
            }
        }
        subdivClickBuffer = ClickSoundFactory.buffer(sampleRate: sampleRate, accent: .soft, tone: "subtle")
    }

    func start() {
        guard !isPlaying else { return }
        do { try setupEngine() } catch {
            NSLog("MetronomeEngine start failed: \(error)")
            return
        }
        prepareHapticsIfNeeded()
        markers.removeAll(keepingCapacity: true)
        primaryBeatIndex = 0
        secondaryBeatIndex = 0
        countInBeatIndex = 0
        beatsScheduled = 0
        inCountIn = countInBars > 0
        let startAhead = AVAudioFramePosition(sampleRate * 0.12)
        if let lastTime = player.lastRenderTime {
            primaryNextSampleTime = lastTime.sampleTime + startAhead
        } else {
            primaryNextSampleTime = startAhead
        }
        secondaryNextSampleTime = primaryNextSampleTime
        player.play()
        isPlaying = true
        let t = DispatchSource.makeTimerSource(queue: scheduleQueue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        isPlaying = false
        inCountIn = false
    }

    private func rebuildSchedule() {
        player.stop()
        if let lastTime = player.lastRenderTime {
            primaryNextSampleTime = lastTime.sampleTime + AVAudioFramePosition(sampleRate * 0.12)
            secondaryNextSampleTime = primaryNextSampleTime
        }
        primaryBeatIndex = 0
        secondaryBeatIndex = 0
        beatsScheduled = 0
        player.play()
        tick()
    }

    private func tick() {
        guard isPlaying else { return }
        guard let now = player.lastRenderTime else { return }
        let lookAheadFrames = AVAudioFramePosition(sampleRate * lookAheadSeconds)
        let horizon = now.sampleTime + lookAheadFrames
        let comp = btLatencyCompensation
            ? AVAudioFramePosition(AudioSessionManager.shared.outputLatency * sampleRate)
            : 0
        ensureAccentLength()

        let numerator = max(1, timeSignature.numerator)

        // Schedule primary track (handles count-in transparently).
        while primaryNextSampleTime < horizon {
            // Determine which "logical" beat this is.
            let totalBeats = primaryBeatIndex
            let inLeadIn = totalBeats < countInBars * numerator
            inCountIn = inLeadIn

            let cycleBeat = inLeadIn
                ? (totalBeats % numerator)
                : ((totalBeats - countInBars * numerator) % numerator)
            let accent = accentPattern[cycleBeat % numerator]

            // For count-in beats: emit visual marker only (or use soft tone) and color via countIn track.
            // For primary beats during ramp: also recompute BPM per-beat.
            let currentBPM = computeCurrentBPM(beatsScheduled: beatsScheduled, inCountIn: inLeadIn)
            let framesPerBeat = AVAudioFramePosition(sampleRate * (60.0 / currentBPM))

            // Audible playback
            if accent != .off {
                if inLeadIn {
                    // Count-in uses a softer tone — pick soft variant unconditionally
                    if let buf = clickBuffers[.soft] {
                        let when = AVAudioTime(sampleTime: primaryNextSampleTime, atRate: sampleRate)
                        player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
                    }
                } else if let buf = clickBuffers[accent] {
                    let when = AVAudioTime(sampleTime: primaryNextSampleTime, atRate: sampleRate)
                    player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
                }
            }

            // Subdivision audible / visual ticks within this beat.
            if subdivision > 1 {
                let subFrames = framesPerBeat / AVAudioFramePosition(subdivision)
                for s in 1..<subdivision {
                    let subWhen = primaryNextSampleTime + subFrames * AVAudioFramePosition(s)
                    if subdivisionAudible, let buf = subdivClickBuffer {
                        let when = AVAudioTime(sampleTime: subWhen, atRate: sampleRate)
                        player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
                    }
                    let host = hostTime(forSampleTime: subWhen - comp, anchor: now)
                    let marker = BeatMarker(hostTime: host, accent: .soft, trackId: BeatTrack.subdivision.rawValue, bpm: currentBPM)
                    DispatchQueue.main.async { [weak self] in self?.append(marker: marker) }
                }
            }

            // Primary visual marker (use countIn track id when in lead-in).
            let trackId: UInt8 = inLeadIn ? BeatTrack.countIn.rawValue : BeatTrack.primary.rawValue
            let hostTime = self.hostTime(forSampleTime: primaryNextSampleTime - comp, anchor: now)
            let marker = BeatMarker(hostTime: hostTime, accent: accent, trackId: trackId, bpm: currentBPM)
            DispatchQueue.main.async { [weak self] in self?.append(marker: marker) }

            if hapticOnBeat && !inLeadIn { fireHaptic(for: accent) }

            primaryNextSampleTime += framesPerBeat
            primaryBeatIndex += 1
            if !inLeadIn { beatsScheduled += 1 }
        }

        // Schedule polyrhythm secondary if active.
        if case .polyrhythm(let sec) = mode, sec > 0 {
            let primaryBarFrames = AVAudioFramePosition(sampleRate * (60.0 / bpm) * Double(numerator))
            let secondaryFramesPerBeat = primaryBarFrames / AVAudioFramePosition(sec)
            // Align secondary to the start of the active (non-count-in) cycle.
            if secondaryBeatIndex == 0 {
                let leadInFrames = AVAudioFramePosition(Double(countInBars * numerator) * sampleRate * 60.0 / bpm)
                secondaryNextSampleTime = (primaryNextSampleTime - AVAudioFramePosition(Double(primaryBeatIndex) * sampleRate * 60.0 / bpm)) + leadInFrames
                if secondaryNextSampleTime < primaryNextSampleTime - lookAheadFrames {
                    secondaryNextSampleTime = primaryNextSampleTime
                }
            }
            while secondaryNextSampleTime < horizon {
                // Don't audibly play the secondary track during count-in.
                let inLeadIn = inCountIn && countInBars > 0
                if !inLeadIn, let buf = clickBuffers[.normal] {
                    let when = AVAudioTime(sampleTime: secondaryNextSampleTime, atRate: sampleRate)
                    player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
                }
                let host = hostTime(forSampleTime: secondaryNextSampleTime - comp, anchor: now)
                let marker = BeatMarker(hostTime: host, accent: .normal, trackId: BeatTrack.secondary.rawValue, bpm: bpm)
                DispatchQueue.main.async { [weak self] in self?.append(marker: marker) }
                secondaryNextSampleTime += secondaryFramesPerBeat
                secondaryBeatIndex += 1
            }
        }
    }

    private func computeCurrentBPM(beatsScheduled: Int, inCountIn: Bool) -> Double {
        if inCountIn { return bpm }
        if case .gradual(let s, let e, let bars) = mode {
            let totalBeats = max(1, bars * timeSignature.numerator)
            let t = min(1.0, Double(beatsScheduled) / Double(totalBeats))
            return s + (e - s) * t
        }
        return bpm
    }

    private func hostTime(forSampleTime sampleTime: AVAudioFramePosition, anchor: AVAudioTime) -> UInt64 {
        let t = AVAudioTime(sampleTime: sampleTime, atRate: sampleRate)
        return t.extrapolateTime(fromAnchor: anchor)?.hostTime ?? mach_absolute_time()
    }

    private func append(marker: BeatMarker) {
        markers.append(marker)
        if markers.count > markersMax {
            markers.removeFirst(markers.count - markersMax)
        }
        onScheduleMarker?(marker)
    }

    func fadeOut(duration: TimeInterval = 0.3) {
        guard isPlaying else { return }
        let steps = 12
        let interval = duration / Double(steps)
        let original = mixer.outputVolume
        for s in 1...steps {
            scheduleQueue.asyncAfter(deadline: .now() + interval * Double(s)) { [weak self] in
                guard let self else { return }
                let frac = Float(s) / Float(steps)
                self.mixer.outputVolume = original * (1 - frac)
                if s == steps {
                    DispatchQueue.main.async {
                        self.stop()
                        self.mixer.outputVolume = original
                    }
                }
            }
        }
    }

    // MARK: - Tap tempo
    private var tapTimes: [TimeInterval] = []
    func registerTap(now: TimeInterval = CACurrentMediaTime()) {
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst(tapTimes.count - 8) }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes, tapTimes.dropFirst()).map { $1 - $0 }
        let median = intervals.sorted()[intervals.count / 2]
        if median > 0 {
            let raw = 60.0 / median
            var n = raw
            while n < 40 { n *= 2 }
            while n > 240 { n /= 2 }
            bpm = (n * 10).rounded() / 10
        }
    }

    // MARK: - Haptics
    private func prepareHapticsIfNeeded() {
        guard hapticOnBeat, hapticEngine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            try e.start()
            hapticEngine = e
        } catch {
            NSLog("Haptic engine failed: \(error)")
        }
    }

    private func fireHaptic(for accent: Accent) {
        guard let engine = hapticEngine else { return }
        let intensity: Float
        switch accent {
        case .accent: intensity = 1.0
        case .normal: intensity = 0.6
        case .soft, .off: return
        }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // ignore
        }
    }
}
