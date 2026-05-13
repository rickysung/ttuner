import Foundation
import Observation
import CoreMotion
import QuartzCore
import UIKit

@Observable
final class AppState {
    // Sub-states
    let tuner = TunerState()
    let metronome = MetronomeEngine()
    @ObservationIgnored let intonationHistory = IntonationHistory(capacity: 2048)

    // Display
    var orientation: AppOrientation = .portrait
    var scrubMode: ScrubMode = .live
    var zoomMinHz: Float = 50
    var zoomMaxHz: Float = 4_000

    // Settings live mirror
    var settings: AppSettings {
        didSet { settings.save(); applySettings() }
    }

    // Soft feature signals
    var rmsDb: Float = -100
    var permissionDenied: Bool = false
    var showSettings: Bool = false
    var showMetronomeSheet: Bool = false
    var pausedToastVisible: Bool = false
    var autoTuneInSuggestion: Double? = nil
    var pendingShareItems: [URL] = []
    var showShareSheet: Bool = false
    var motionState: MotionState = .unknown
    /// Glow alpha in [0,1] for the screen edges. The view picks color from the sign.
    var loudnessGlowLevel: Float = 0
    /// Negative value = too quiet (yellow), positive = too loud (red).
    var loudnessGlowSign: Float = 0
    /// 0..1 scalar applied to glass cards & spectrogram in Discreet Mode.
    var discreetDim: Float = 0

    // Internal
    @ObservationIgnored private var captureEngine: CaptureEngine?
    @ObservationIgnored private var analysisEngine: AnalysisEngine?
    @ObservationIgnored private var timeline: TimelineRingBuffer?
    @ObservationIgnored private var bridge: SpectrogramBridge?
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var onsetHistory: [TimeInterval] = []
    @ObservationIgnored private var prevSpectrum: [Float]?
    @ObservationIgnored private var lastSilentSince: TimeInterval?
    @ObservationIgnored private var lastStableAccelDate: Date?
    @ObservationIgnored private var lastMovingAccelDate: Date?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var brightnessObserver: NSObjectProtocol?

    enum MotionState { case unknown, stable, moving, paused }

    init() {
        self.settings = AppSettings.load()
        zoomMinHz = settings.zoomMinHz
        zoomMaxHz = settings.zoomMaxHz
    }

    // MARK: - Lifecycle
    func bootstrap(bridge: SpectrogramBridge) {
        self.bridge = bridge
        applySettings()
        guard !didBootstrap else { return }
        didBootstrap = true
        AudioSessionManager.shared.configure(mode: settings.sessionMode,
                                             preferredSampleRate: settings.sampleRatePreference)
        AudioSessionManager.shared.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.permissionDenied = false
                self.startEngines()
            } else {
                self.permissionDenied = true
            }
        }
        startMotionMonitoring()
        observeBrightness()
    }

    func teardown() {
        analysisEngine?.stop()
        captureEngine?.stop()
        metronome.stop()
        motion.stopDeviceMotionUpdates()
        if let o = brightnessObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private func startEngines() {
        let capture = CaptureEngine(capacitySeconds: 12)
        do {
            try capture.start()
        } catch {
            NSLog("CaptureEngine failed: \(error)")
            return
        }
        self.captureEngine = capture

        let sr = Float(capture.sampleRate)
        let timelineCapacity = max(1, Int(Double(settings.timelineSeconds) * (Double(sr) / Double(settings.hopSize))))
        let tl = TimelineRingBuffer(capacityColumns: timelineCapacity, columnHeight: settings.displayBins)
        self.timeline = tl

        let analysis = AnalysisEngine(
            ringBuffer: capture.ringBuffer,
            sampleRate: sr,
            fftSize: settings.fftSize,
            hopSize: settings.hopSize,
            displayBins: settings.displayBins,
            minHz: 20,
            maxHz: min(sr / 2, 20_000)
        )
        bridge?.contentMinHz = 20
        bridge?.contentMaxHz = min(sr / 2, 20_000)

        analysis.onSpectrumFrame = { [weak self] frame in
            guard let self else { return }
            DispatchQueue.main.async {
                tl.write(frame)
                self.bridge?.append(column: frame.bins)
                self.evaluateOnsetForAutoTuneIn(frame)
            }
        }
        analysis.onPitchEvent = { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async { self.handlePitch(event: event) }
        }
        analysis.onRMSUpdate = { [weak self] db in
            guard let self else { return }
            DispatchQueue.main.async {
                self.rmsDb = db
                self.updateLoudnessGlow(db: db)
                self.evaluateSilenceAwarePause(db: db)
            }
        }
        analysis.start()
        self.analysisEngine = analysis
    }

    private func handlePitch(event: PitchEvent?) {
        guard let event else {
            tuner.update(with: nil, reading: nil, stabilityCents: settings.stabilityCents)
            bridge?.updatePitchTrail(tuner.trail, referenceA: settings.referenceA, transpose: settings.transpose)
            return
        }
        let reading = NoteMapper.map(
            f0: event.f0,
            referenceA: settings.referenceA,
            transpose: settings.transpose,
            display: settings.noteDisplay
        )
        tuner.update(with: event, reading: reading, stabilityCents: settings.stabilityCents)
        if let r = reading {
            let mag = Float(min(50, abs(r.cents))) / 50.0
            intonationHistory.append(hostTime: event.hostTime, magnitude: mag)
        }
        bridge?.updatePitchTrail(tuner.trail, referenceA: settings.referenceA, transpose: settings.transpose)
        // When scrubbing, also push the heatmap snapshot each pitch tick.
        if scrubMode.isLive == false, settings.intonationHeatmap {
            let snap = intonationHistory.snapshot(secondsBack: Double(zoomVisibleSeconds))
            bridge?.updateHeatmap(snap)
        }
    }

    private var zoomVisibleSeconds: Float { bridge?.visibleSeconds ?? 8 }

    // MARK: - Settings application
    func applySettings() {
        bridge?.dbFloor = settings.dbFloor
        bridge?.dbCeil = settings.dbCeil
        bridge?.colormap = settings.colormap
        bridge?.displayMinHz = max(20, zoomMinHz)
        bridge?.displayMaxHz = zoomMaxHz
        metronome.hapticOnBeat = settings.hapticOnBeat
        metronome.btLatencyCompensation = settings.btLatencyCompensation
        if !metronome.isPlaying {
            metronome.bpm = settings.defaultBPM
            metronome.timeSignature = settings.defaultTimeSignature
            metronome.accentPattern = TimeSignature.defaultAccentPattern(for: settings.defaultTimeSignature)
            metronome.countInBars = settings.countInBars
        }
        // Heatmap visibility follows scrub mode + setting toggle.
        bridge?.heatmapEnabled = !scrubMode.isLive && settings.intonationHeatmap
        applyDiscreetMode(forceImmediate: false)
    }

    // MARK: - Orientation
    func updateOrientation(_ orientation: AppOrientation) {
        self.orientation = orientation
        bridge?.orientation = orientation
    }

    // MARK: - Zoom
    func setZoom(minHz: Float, maxHz: Float) {
        zoomMinHz = max(20, min(maxHz - 10, minHz))
        zoomMaxHz = max(zoomMinHz + 10, min(20_000, maxHz))
        bridge?.displayMinHz = zoomMinHz
        bridge?.displayMaxHz = zoomMaxHz
    }

    func resetZoom() { setZoom(minHz: 50, maxHz: 4_000) }

    // MARK: - Scrub
    func toggleScrub() {
        switch scrubMode {
        case .live:
            scrubMode = .paused(offsetSeconds: 0)
            pausedToastVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.pausedToastVisible = false
            }
        case .paused:
            scrubMode = .live
        }
        bridge?.scrubMode = scrubMode
        bridge?.heatmapEnabled = !scrubMode.isLive && settings.intonationHeatmap
        if !scrubMode.isLive {
            let snap = intonationHistory.snapshot(secondsBack: Double(zoomVisibleSeconds))
            bridge?.updateHeatmap(snap)
        }
    }

    func nudgeScrub(deltaSeconds: Double) {
        guard case .paused(let off) = scrubMode else { return }
        let next = max(0, off + deltaSeconds)
        scrubMode = .paused(offsetSeconds: next)
        bridge?.scrubMode = scrubMode
    }

    // MARK: - Auto Export
    func exportVisibleClip() {
        var urls: [URL] = []
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        if let view = bridge?.metalView,
           let png = Exporter.snapshot(view: view, name: "ttuner-\(stamp)") {
            urls.append(png)
        }
        if let rb = captureEngine?.ringBuffer,
           let sr = captureEngine?.sampleRate,
           let wav = Exporter.writeRecentAudio(buffer: rb,
                                               sampleRate: sr,
                                               seconds: 10,
                                               name: "ttuner-\(stamp)") {
            urls.append(wav)
        }
        guard !urls.isEmpty else { return }
        pendingShareItems = urls
        showShareSheet = true
    }

    // MARK: - Auto-tune-in
    private func evaluateOnsetForAutoTuneIn(_ frame: SpectrumFrame) {
        guard settings.autoTuneIn, metronome.isPlaying == false else { return }
        if let prev = prevSpectrum, prev.count == frame.bins.count {
            var flux: Float = 0
            for i in 0..<frame.bins.count {
                let d = frame.bins[i] - prev[i]
                if d > 0 { flux += d }
            }
            if flux > 80 {
                let now = CACurrentMediaTime()
                if let last = onsetHistory.last, now - last < 0.06 {
                    // ignore
                } else {
                    onsetHistory.append(now)
                    if onsetHistory.count > 8 { onsetHistory.removeFirst(onsetHistory.count - 8) }
                    autoTuneInSuggestion = estimateBPMFromOnsets(onsetHistory)
                }
            }
        }
        prevSpectrum = frame.bins
    }

    private func estimateBPMFromOnsets(_ onsets: [TimeInterval]) -> Double? {
        guard onsets.count >= 6 else { return nil }
        let intervals = zip(onsets, onsets.dropFirst()).map { $1 - $0 }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return nil }
        var n = 60.0 / median
        while n < 40 { n *= 2 }
        while n > 240 { n /= 2 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        let cv = sqrt(variance) / mean
        return cv < 0.12 ? (n * 10).rounded() / 10 : nil
    }

    func acceptAutoTuneInSuggestion() {
        if let s = autoTuneInSuggestion {
            settings.defaultBPM = s
            metronome.bpm = s
            autoTuneInSuggestion = nil
        }
    }

    func dismissAutoTuneInSuggestion() { autoTuneInSuggestion = nil }

    // MARK: - Silence-aware pause
    private func evaluateSilenceAwarePause(db: Float) {
        guard settings.silenceAwarePause, metronome.isPlaying else {
            lastSilentSince = nil
            return
        }
        let now = CACurrentMediaTime()
        if db < settings.silenceThresholdDb {
            if lastSilentSince == nil { lastSilentSince = now }
            if let since = lastSilentSince, now - since >= settings.silenceSeconds {
                metronome.fadeOut()
                lastSilentSince = nil
            }
        } else {
            lastSilentSince = nil
        }
    }

    // MARK: - Loudness glow
    private func updateLoudnessGlow(db: Float) {
        guard settings.loudnessGlow else {
            loudnessGlowLevel = 0
            loudnessGlowSign = 0
            return
        }
        // Mapping: < -40dB → quiet (yellow), > -3dB → loud (red), else 0
        if db < -40 {
            let mag = min(1, max(0, (-40 - db) / 30.0))
            loudnessGlowLevel = mag
            loudnessGlowSign = -1
        } else if db > -3 {
            let mag = min(1, max(0, (db - -3) / 20.0))
            loudnessGlowLevel = mag
            loudnessGlowSign = 1
        } else {
            loudnessGlowLevel = max(0, loudnessGlowLevel - 0.05)
            if loudnessGlowLevel == 0 { loudnessGlowSign = 0 }
        }
    }

    // MARK: - Discreet Mode (auto by ambient brightness)
    private func observeBrightness() {
        brightnessObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDiscreetMode(forceImmediate: false)
        }
        applyDiscreetMode(forceImmediate: true)
    }

    private func applyDiscreetMode(forceImmediate: Bool) {
        guard settings.discreetModeAuto else {
            discreetDim = 0
            return
        }
        // Heuristic: brightness < 0.25 → dim glass cards & spectrogram.
        let brightness = UIScreen.main.brightness
        let target: Float = brightness < 0.25 ? 0.3 : 0.0
        if forceImmediate {
            discreetDim = target
        } else {
            // Smoothly transition.
            let step: Float = 0.05
            if abs(target - discreetDim) < step {
                discreetDim = target
            } else {
                discreetDim += (target > discreetDim ? step : -step)
            }
        }
    }

    // MARK: - Motion monitoring
    private func startMotionMonitoring() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self, let data else { return }
            let mag = sqrt(data.userAcceleration.x * data.userAcceleration.x +
                           data.userAcceleration.y * data.userAcceleration.y +
                           data.userAcceleration.z * data.userAcceleration.z)
            self.processMotion(magnitude: mag)
        }
    }

    private func processMotion(magnitude: Double) {
        guard settings.movementAwarePause else { return }
        let stableTh = settings.motionSensitivity.stableThreshold
        let movingTh = settings.motionSensitivity.movingThreshold
        let now = Date()
        switch motionState {
        case .unknown:
            if magnitude < stableTh {
                if lastStableAccelDate == nil { lastStableAccelDate = now }
                if let s = lastStableAccelDate, now.timeIntervalSince(s) > 5 {
                    motionState = .stable
                }
            } else {
                lastStableAccelDate = nil
            }
        case .stable:
            if magnitude > movingTh {
                if lastMovingAccelDate == nil { lastMovingAccelDate = now }
                if let m = lastMovingAccelDate, now.timeIntervalSince(m) > 0.5 {
                    motionState = .paused
                    if metronome.isPlaying { metronome.fadeOut() }
                    lastMovingAccelDate = nil
                }
            } else {
                lastMovingAccelDate = nil
            }
        case .moving:
            if magnitude < stableTh { motionState = .stable }
        case .paused:
            if magnitude < stableTh, settings.autoResume {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self else { return }
                    if self.motionState == .paused { self.metronome.start() }
                }
            }
        }
    }
}
