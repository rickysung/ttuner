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

    // Observed beat marker queue (most-recent appended)
    private(set) var markers: [BeatMarker] = []
    private let markersMax = 96

    // Engine
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()

    // Click cache: [Accent : buffer]
    private var clickBuffers: [Accent: AVAudioPCMBuffer] = [:]
    private var sampleRate: Double = 44_100

    // Scheduling
    private var nextBeatIndex: Int = 0
    private var nextSampleTime: AVAudioFramePosition = 0
    private let lookAheadSeconds: Double = 0.5
    private var scheduleQueue = DispatchQueue(label: "ttuner.metronome.schedule")
    private var timer: DispatchSourceTimer?

    // Visual marker callback (Metal renderer hooks into this)
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
    }

    func start() {
        guard !isPlaying else { return }
        do { try setupEngine() } catch {
            NSLog("MetronomeEngine start failed: \(error)")
            return
        }
        prepareHapticsIfNeeded()
        markers.removeAll(keepingCapacity: true)
        nextBeatIndex = 0
        // Start ~120ms in the future so first click isn't clipped.
        if let lastTime = player.lastRenderTime,
           let _ = player.playerTime(forNodeTime: lastTime) {
            nextSampleTime = lastTime.sampleTime + AVAudioFramePosition(sampleRate * 0.12)
        } else {
            nextSampleTime = AVAudioFramePosition(sampleRate * 0.12)
        }
        player.play()
        isPlaying = true
        rebuildSchedule()
        // Tick the scheduler ~every 100ms to refill the look-ahead window.
        let t = DispatchSource.makeTimerSource(queue: scheduleQueue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(100))
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
    }

    private func rebuildSchedule() {
        // Stop everything pending and re-prime from the next scheduled time.
        player.stop()
        if let lastTime = player.lastRenderTime {
            nextSampleTime = lastTime.sampleTime + AVAudioFramePosition(sampleRate * 0.12)
        }
        player.play()
        tick()
    }

    private func tick() {
        guard isPlaying else { return }
        guard let now = player.lastRenderTime else { return }
        let lookAheadFrames = AVAudioFramePosition(sampleRate * lookAheadSeconds)
        let horizon = now.sampleTime + lookAheadFrames
        let framesPerBeat = AVAudioFramePosition(sampleRate * (60.0 / bpm))
        ensureAccentLength()
        let comp = btLatencyCompensation
            ? AVAudioFramePosition(AudioSessionManager.shared.outputLatency * sampleRate)
            : 0
        while nextSampleTime < horizon {
            let accent = accentPattern[nextBeatIndex % accentPattern.count]
            if accent != .off, let buf = clickBuffers[accent] {
                let when = AVAudioTime(sampleTime: nextSampleTime, atRate: sampleRate)
                player.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
            }
            // Emit a marker host time aligned to the same scheduled point, minus BT latency.
            let hostTime = AVAudioTime(sampleTime: nextSampleTime - comp, atRate: sampleRate)
                .extrapolateTime(fromAnchor: now)?.hostTime ?? mach_absolute_time()
            let marker = BeatMarker(hostTime: hostTime, accent: accent, trackId: 0, bpm: bpm)
            DispatchQueue.main.async { [weak self] in self?.append(marker: marker) }
            if hapticOnBeat { fireHaptic(for: accent) }
            nextSampleTime += framesPerBeat
            nextBeatIndex += 1
        }
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
        var current: Float = mixer.outputVolume
        for s in 1...steps {
            scheduleQueue.asyncAfter(deadline: .now() + interval * Double(s)) { [weak self] in
                guard let self else { return }
                let frac = Float(s) / Float(steps)
                self.mixer.outputVolume = current * (1 - frac)
                if s == steps {
                    DispatchQueue.main.async {
                        self.stop()
                        self.mixer.outputVolume = 1
                        current = 1
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
            // Silently ignore haptic failures during playback
        }
    }
}
