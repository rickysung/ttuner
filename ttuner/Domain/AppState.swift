import Foundation
import Observation
import CoreMotion
import QuartzCore
import UIKit
import ActivityKit

@Observable
final class AppState {
    // Sub-states
    var tuner = TunerState()
    var metronome = MetronomeEngine()
    /// StoreKit-backed Pro entitlement. Single source of truth for
    /// every gate elsewhere in the UI. Reads `ProStore.shared` so
    /// the same instance survives across the app lifetime.
    var pro: ProStore { ProStore.shared }
    /// Set by gate sites (Pro feature taps) and observed by
    /// `ContentView` to present the paywall sheet.
    var showPaywall: Bool = false
    @ObservationIgnored let intonationHistory = IntonationHistory(capacity: 2048)

    // Display
    var orientation: AppOrientation = .portrait
    var scrubMode: ScrubMode = .live
    var zoomMinHz: Float = 50
    var zoomMaxHz: Float = 4_000
    /// Width of the pitch grid in semitones — the half-octave default
    /// (6) is also the minimum (most zoomed-in). User can pinch out to
    /// widen up to two octaves (24). Only affects visual scaling of
    /// grid + dots + labels; the flame shader is independent.
    var visibleSemitones: Float = 6 {
        didSet { bridge?.visibleSemitones = visibleSemitones }
    }
    static let visibleSemitonesMin: Float = 6
    static let visibleSemitonesMax: Float = 24

    // Settings live mirror
    var settings: AppSettings {
        didSet {
            settings.save()
            if settings.tuningPresetId != oldValue.tuningPresetId {
                // Different instrument selected — last session's
                // checkmarks no longer apply.
                tunedStringIndices.removeAll()
                activeStringIndex = nil
            }
            // Any settings mutation could affect the preset/label cache
            // (preset id, transpose, sharp/flat, or the customs blob).
            // Cheaper to invalidate unconditionally than to compare each
            // dependency — `refreshPresetCacheIfNeeded()` will rebuild
            // only when an actual key field changed.
            _cachedPresetId = ""
            applySettings()
        }
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
    @ObservationIgnored private var lastStableAccelDate: Date?
    @ObservationIgnored private var lastMovingAccelDate: Date?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var metronomePausedByScrub: Bool = false
    /// Horizontal-drag offset (in semitones) while the user is in scrub
    /// mode. Reset to 0 each time scrub starts. Propagated to the
    /// renderer via the bridge so the shader's `cameraSemitone` slides
    /// left/right around the scrub-entry pitch.
    @ObservationIgnored private(set) var scrubCameraOffsetSemitones: Float = 0 {
        didSet { bridge?.scrubCameraOffsetSemitones = scrubCameraOffsetSemitones }
    }
    @ObservationIgnored private var brightnessObserver: NSObjectProtocol?

    enum MotionState { case unknown, stable, moving, paused }

    // MARK: - Tuning-preset state
    //
    // Mirrored from settings so it's observable. Indices reference
    // `selectedTuningPreset.midiNotes`.

    /// The index of the preset's note that is *currently* nearest to
    /// the live pitch. `nil` when chromatic / no reading.
    var activeStringIndex: Int? = nil
    /// Indices that have been observed locked in tune at least once
    /// since this preset became active. Cleared whenever the user
    /// switches preset.
    var tunedStringIndices: Set<Int> = []

    /// Cached resolution of the current preset id against the built-in
    /// + custom list. Recomputed in `refreshPresetCache()` whenever the
    /// preset id or the custom list changes — avoids a linear scan on
    /// every 20 Hz pitch event.
    @ObservationIgnored private var _cachedPresetId: String = ""
    @ObservationIgnored private var _cachedPreset: TuningPreset = TuningPresets.chromatic
    /// Per-string labels for the cached preset. Reused by both the
    /// SwiftUI string row and the PIP push so we don't `NoteMapper.label`
    /// six times per pitch event.
    @ObservationIgnored private var _cachedPresetLabels: [String] = []

    var selectedTuningPreset: TuningPreset {
        // Tracking-safe read: the cache key includes everything the
        // resolved preset depends on, so observers of the right field
        // re-render at the right time.
        refreshPresetCacheIfNeeded()
        return _cachedPreset
    }

    /// All presets including user-defined customs. Used by the
    /// settings picker and the drone panel's pitch-source rows.
    var allTuningPresets: [TuningPreset] {
        TuningPresets.all(includingCustom: settings.customTunings)
    }

    /// Recompute the resolved preset + labels when (and only when)
    /// the inputs have changed. Cheap enough to call from hot paths.
    private func refreshPresetCacheIfNeeded() {
        // Cache key combines preset id with the rendered transpose +
        // sharp/flat state, since the per-string *labels* depend on
        // those even if the preset itself didn't change.
        let key = "\(settings.tuningPresetId)|\(settings.transpose)|\(settings.noteDisplay.rawValue)"
        guard key != _cachedPresetId else { return }
        _cachedPresetId = key
        _cachedPreset = TuningPresets.find(id: settings.tuningPresetId,
                                            customs: settings.customTunings)
        _cachedPresetLabels = _cachedPreset.midiNotes.map { midi in
            NoteMapper.label(forMidi: midi, display: settings.noteDisplay)
        }
    }

    /// Latest snapshot of the metronome's playback shape — bar anchor,
    /// bpm, accents. Driven by `MetronomeEngine.onMetronomeState`. The
    /// status chip and PIP overlay TimelineView from `barStartDate` so
    /// the currently-playing beat dot lights up.
    var metronomePlaybackState: MetronomeEngine.PlaybackState? = nil

    /// Drone engine. Exposed so UI bindings can observe playback state
    /// (`drone.currentMidi`) and call start/stop. Pro-gated at the UI
    /// entry points — the engine itself stays dumb.
    var drone: DroneEngine { DroneEngine.shared }

    init() {
        self.settings = AppSettings.load()
        zoomMinHz = settings.zoomMinHz
        zoomMaxHz = settings.zoomMaxHz
        wireMetronomeStateHooks()
    }

    /// Forward the metronome's playback shape changes (start, stop, BPM
    /// change, time-sig change, etc.) into AppState — and into the PIP
    /// controller so the floating tuner can show beat dots too.
    private func wireMetronomeStateHooks() {
        metronome.onMetronomeState = { [weak self] state in
            self?.metronomePlaybackState = state
            TunerPIPController.shared.updateMetronome(state)
        }
    }

    // MARK: - Lifecycle
    func bootstrap(bridge: SpectrogramBridge) {
        self.bridge = bridge
        applySettings()
        guard !didBootstrap else { return }
        didBootstrap = true
        endStaleLiveActivities()
        // Wait until StoreKit has actually resolved the user's
        // entitlement before downgrading anything — the initial
        // `pro.isPro = false` is a transient pre-fetch state, not
        // "user is on the free tier".
        Task { [weak self] in
            await ProStore.shared.refresh()
            await MainActor.run { self?.enforceProGates() }
        }
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

    /// Force free-tier defaults for any Pro-gated setting whenever the
    /// user is not entitled. Runs at launch and is called again from
    /// `ContentView` whenever `pro.isPro` flips (e.g. a refund came in
    /// while the app was open). Keeps the UI honest without burying
    /// guards inside every read site.
    func enforceProGates() {
        guard !pro.isPro else { return }
        if settings.tuningPresetId != "chromatic" {
            settings.tuningPresetId = "chromatic"
        }
        if settings.speedTrainerEnabled {
            settings.speedTrainerEnabled = false
        }
        // Custom tunings stay in the saved blob even when downgraded —
        // wiping them on every entitlement flip would punish a user
        // who simply ran out of trial. The picker just hides them.
        // Drone mode toggle and any in-flight drone, however, are
        // strictly Pro and revert here.
        if settings.droneModeEnabled {
            settings.droneModeEnabled = false
        }
        if drone.isPlaying {
            stopDrone()
        }
    }

    /// Kill any Live Activities our previous Dynamic-Island prototype
    /// left running on the device. ActivityKit activities outlive their
    /// host app — without this, a long-stale tuner pill keeps showing
    /// even though the new build doesn't push to it anymore.
    private func endStaleLiveActivities() {
        for activity in Activity<TtunerActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
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
        // Wire the metronome's player → mixer → mainMixerNode chain on
        // the shared AVAudioEngine BEFORE CaptureEngine boots that
        // engine. Modifying a running graph from a second client
        // crashes the audio I/O thread.
        metronome.configureGraph()

        let capture = CaptureEngine(capacitySeconds: 12)
        do {
            try capture.start()
        } catch {
            NSLog("CaptureEngine failed: \(error)")
            return
        }
        self.captureEngine = capture

        let sr = Float(capture.sampleRate)
        let cqtBins = AnalysisEngine.cqtBinCount
        let timelineCapacity = max(1, Int(Double(settings.timelineSeconds) * (Double(sr) / Double(settings.hopSize))))
        let tl = TimelineRingBuffer(capacityColumns: timelineCapacity, columnHeight: cqtBins)
        self.timeline = tl

        let analysis = AnalysisEngine(
            ringBuffer: capture.ringBuffer,
            sampleRate: sr,
            hopSize: settings.hopSize
        )
        // The CQT defines exactly which frequencies its output bins represent,
        // so the shader's "content range" must match those endpoints — using
        // 20 Hz / Nyquist here would offset every bin in the spectrogram.
        bridge?.contentMinHz = AnalysisEngine.cqtMinHz
        bridge?.contentMaxHz = AnalysisEngine.cqtMaxHz
        bridge?.framesPerSecond = sr / Float(settings.hopSize)

        analysis.onSpectrumFrame = { [weak self] frame in
            guard let self else { return }
            DispatchQueue.main.async {
                // Timeline keeps recording for export/heatmap regardless of
                // scrub state, but the live spectrogram is frozen while the
                // user is inspecting the past.
                tl.write(frame)
                if self.scrubMode.isLive {
                    self.bridge?.append(column: frame.bins, rmsDb: frame.rmsDb)
                }
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
            }
        }
        analysis.start()
        self.analysisEngine = analysis
    }

    private func handlePitch(event: PitchEvent?) {
        // While the user is inspecting history, freeze every live signal:
        // the tuner card holds its last reading, the camera doesn't slide
        // to chase new input, and no new pitch dots are appended (they'd
        // appear at the top of the frozen window with stale host-times).
        guard scrubMode.isLive else { return }
        guard let event else {
            tuner.update(with: nil, reading: nil, stabilityCents: settings.stabilityCents)
            // Tell the renderer there is no live pitch — the camera holds and
            // the particle color eases back to neutral.
            bridge?.updateLivePitch(semitone: nil, clarity: 0, rmsDb: rmsDb)
            return
        }
        let reading = NoteMapper.map(
            f0: event.f0,
            referenceA: settings.referenceA,
            transpose: settings.transpose,
            display: settings.noteDisplay
        )
        tuner.update(with: event, reading: reading, stabilityCents: settings.stabilityCents)
        // Continuous MIDI semitone: 69 + 12·log2(f0 / referenceA).
        let refA = Float(settings.referenceA)
        let semitone = (69.0 as Float) + 12.0 * log2(event.f0 / refA) - Float(settings.transpose)
        if event.clarity > 0.5 {
            bridge?.appendPitch(hostTime: event.hostTime,
                                 semitone: semitone,
                                 clarity: event.clarity,
                                 rmsDb: rmsDb)
            bridge?.updateLivePitch(semitone: semitone, clarity: event.clarity, rmsDb: rmsDb)
        } else {
            bridge?.updateLivePitch(semitone: nil, clarity: event.clarity, rmsDb: rmsDb)
        }
        if let r = reading {
            let mag = Float(min(50, abs(r.cents))) / 50.0
            intonationHistory.append(hostTime: event.hostTime, magnitude: mag)
            TunerPIPController.shared.updateReading(
                noteLabel: r.label,
                cents: r.cents,
                frequency: Double(event.f0),
                isStable: tuner.stable
            )
            updateTuningPresetState(reading: r)
        } else if activeStringIndex != nil {
            // We just lost a reading — clear the PIP and active-string
            // hint once. The guard skips the (very common) case where
            // the user is between notes and we'd otherwise push the
            // same "nil" snapshot 20× a second.
            TunerPIPController.shared.updateReading(
                noteLabel: nil,
                cents: 0,
                frequency: 0,
                isStable: false
            )
            activeStringIndex = nil
        }
    }

    /// Find the preset string nearest to the current pitch (in
    /// continuous MIDI space, so a B between B3 and C4 is decided
    /// honestly) and mark it tuned once it sustains in tolerance.
    private func updateTuningPresetState(reading: NoteReading) {
        let preset = selectedTuningPreset
        guard !preset.isChromatic else {
            activeStringIndex = nil
            pushPresetToPIP()
            return
        }
        let continuousMidi = Double(reading.midi) + reading.cents / 100.0
        var bestIdx = 0
        var bestDist = Double.infinity
        for (i, note) in preset.midiNotes.enumerated() {
            let d = abs(continuousMidi - Double(note))
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        activeStringIndex = bestIdx
        // Mark this string tuned once the reading is stable AND within
        // a tight tolerance (cents space) of the target. Same threshold
        // as the in-tune blue glow elsewhere so the UI tells one story.
        let centsToTarget = abs(continuousMidi - Double(preset.midiNotes[bestIdx])) * 100
        if tuner.stable, centsToTarget < Double(settings.stabilityCents) {
            tunedStringIndices.insert(bestIdx)
        }
        pushPresetToPIP()
    }

    /// Hand the current preset shape to `TunerPIPController` so the
    /// floating window can render its compact strings row. Called from
    /// every pitch-event tick — labels come from the cached array so
    /// no per-event MIDI→label allocations.
    private func pushPresetToPIP() {
        refreshPresetCacheIfNeeded()
        TunerPIPController.shared.updatePreset(
            labels: _cachedPresetLabels,
            activeIndex: activeStringIndex,
            tunedIndices: tunedStringIndices
        )
    }

    // MARK: - Drone

    /// Start (or switch to) a drone for the given MIDI note and push
    /// the resulting state into PIP so the floating tuner shows the
    /// reference pitch the user is playing against.
    func startDrone(midi: Int) {
        drone.start(midi: midi, referenceA: settings.referenceA)
        let label = NoteMapper.label(forMidi: midi, display: settings.noteDisplay)
        TunerPIPController.shared.updateDrone(midi: midi, label: label)
    }

    /// Stop any playing drone. No-op when nothing is playing.
    func stopDrone() {
        drone.stop()
        TunerPIPController.shared.updateDrone(midi: nil, label: nil)
    }

    private var zoomVisibleSeconds: Float { bridge?.visibleSeconds ?? 8 }

    // MARK: - Settings application
    func applySettings() {
        bridge?.dbFloor = settings.dbFloor
        bridge?.dbCeil = settings.dbCeil
        bridge?.colormap = settings.colormap
        bridge?.displayMinHz = max(20, zoomMinHz)
        bridge?.displayMaxHz = zoomMaxHz
        bridge?.volumeBarOpacity = settings.volumeBarOpacity
        bridge?.spectroBlur = settings.spectroBlur
        metronome.btLatencyCompensation = settings.btLatencyCompensation
        if !metronome.isPlaying {
            metronome.bpm = settings.defaultBPM
            metronome.timeSignature = settings.defaultTimeSignature
            metronome.accentPattern = TimeSignature.defaultAccentPattern(for: settings.defaultTimeSignature)
            metronome.countInBars = settings.countInBars
        }
        // Speed Trainer — toggle between `.simple` and `.speedTrainer`
        // without disturbing any `.gradual` mode set elsewhere.
        if settings.speedTrainerEnabled {
            metronome.mode = .speedTrainer(
                startBPM: settings.speedTrainerStartBPM,
                endBPM: settings.speedTrainerEndBPM,
                barsPerStep: settings.speedTrainerBarsPerStep
            )
        } else if case .speedTrainer = metronome.mode {
            metronome.mode = .simple
        }
        // Heatmap visibility follows scrub mode + setting toggle.
        bridge?.heatmapEnabled = !scrubMode.isLive && settings.intonationHeatmap
        applyDiscreetMode(forceImmediate: false)
        // Send the current preset shape over to PIP so a settings-only
        // change (picker swap, transpose, sharp/flat) reaches the
        // floating window even without a fresh pitch event.
        pushPresetToPIP()
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

    func resetZoom() {
        setZoom(minHz: 50, maxHz: 4_000)
        // Reset the pitch-grid pinch range back to the narrowest view.
        visibleSemitones = AppState.visibleSemitonesMin
    }

    func setVisibleSemitones(_ s: Float) {
        let clamped = max(AppState.visibleSemitonesMin,
                          min(AppState.visibleSemitonesMax, s))
        if abs(clamped - visibleSemitones) > 0.001 {
            visibleSemitones = clamped
        }
    }

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

    /// Absolute scrub offset in seconds. 0 (or below) flips the renderer back
    /// to live capture; positive values pause new spectrogram columns and let
    /// the user inspect the recent past. Side effects on the boundary:
    ///   • Entering scrub auto-pauses a playing metronome (the lines on
    ///     screen are frozen, so continuing to tick would just stack
    ///     beats the user can't see).
    ///   • Returning to live auto-resumes only if scrub was the one that
    ///     stopped it — manual stops aren't overridden.
    func setScrubSeconds(_ seconds: Double) {
        if seconds <= 0.0001 {
            // Time axis dragged all the way back to "now" → resume
            // live capture even if there's still a horizontal camera
            // offset in play. `exitScrub` clears that offset too so
            // the camera returns to the live-tracked pitch instead of
            // hovering on whatever the user had panned to.
            if !scrubMode.isLive {
                exitScrub()
            }
            return
        }
        if scrubMode.isLive {
            enterScrub()
        }
        scrubMode = .paused(offsetSeconds: seconds)
        bridge?.scrubMode = scrubMode
        bridge?.heatmapEnabled = settings.intonationHeatmap
        if settings.intonationHeatmap {
            let snap = intonationHistory.snapshot(secondsBack: Double(zoomVisibleSeconds))
            bridge?.updateHeatmap(snap)
        }
    }

    /// Horizontal camera offset while scrubbing. Setting any non-zero
    /// value enters scrub mode at time=0 so a pure left/right pan works
    /// without first scrolling vertically.
    func setScrubCameraOffset(_ semitones: Float) {
        if scrubMode.isLive, semitones != 0 {
            enterScrub()
            scrubMode = .paused(offsetSeconds: 0)
            bridge?.scrubMode = scrubMode
        }
        scrubCameraOffsetSemitones = semitones
    }

    private func enterScrub() {
        if metronome.isPlaying {
            // Use the scrub-specific pause so the markers the user was
            // just hearing remain on screen for inspection. A regular
            // stop() would clear them via onScheduleMarker.
            metronome.pauseForScrub()
            metronomePausedByScrub = true
        }
        scrubCameraOffsetSemitones = 0
    }

    /// Public hook for external observers (scene phase, etc.) to force a
    /// return to live capture. No-op if already live.
    func endScrubIfNeeded() {
        if !scrubMode.isLive {
            exitScrub()
        }
    }

    private func exitScrub() {
        scrubMode = .live
        bridge?.scrubMode = scrubMode
        bridge?.heatmapEnabled = settings.intonationHeatmap && false
        scrubCameraOffsetSemitones = 0
        if metronomePausedByScrub {
            metronomePausedByScrub = false
            metronome.start()
        }
    }

    var currentScrubSeconds: Double {
        if case .paused(let s) = scrubMode { return s }
        return 0
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

    /// Motion state machine — separates "device is currently still"
    /// (stable) from "device just got picked up and metronome should
    /// pause" (paused). Two terminal bugs in the previous version: the
    /// `.moving` case was never assigned, and `.paused` never returned
    /// to `.stable`, so motion-pause only worked once per launch and
    /// piled up duplicate auto-resume timers.
    private func processMotion(magnitude: Double) {
        guard settings.movementAwarePause else {
            // When the feature is disabled, reset state so it starts
            // fresh if the user toggles it back on.
            motionState = .unknown
            lastStableAccelDate = nil
            lastMovingAccelDate = nil
            return
        }
        let stableTh = settings.motionSensitivity.stableThreshold
        let movingTh = settings.motionSensitivity.movingThreshold
        let now = Date()
        switch motionState {
        case .unknown:
            // First reach `.stable` after ~1.5s of stillness so an
            // immediately-after-launch jiggle doesn't trigger a pause.
            if magnitude < stableTh {
                if lastStableAccelDate == nil { lastStableAccelDate = now }
                if let s = lastStableAccelDate, now.timeIntervalSince(s) > 1.5 {
                    motionState = .stable
                    lastStableAccelDate = nil
                }
            } else {
                lastStableAccelDate = nil
            }

        case .stable:
            // Sustained motion above `movingTh` while the metronome is
            // running → pause it. We only act if `isPlaying` so manually
            // stopped metronomes aren't re-touched.
            if magnitude > movingTh, metronome.isPlaying {
                if lastMovingAccelDate == nil { lastMovingAccelDate = now }
                if let m = lastMovingAccelDate, now.timeIntervalSince(m) > 0.5 {
                    metronome.stop()
                    motionState = .paused
                    lastMovingAccelDate = nil
                }
            } else {
                lastMovingAccelDate = nil
            }

        case .paused:
            // Wait for the device to settle for a bit before we re-arm.
            // We deliberately don't auto-resume — let the user tap play
            // themselves so the metronome never starts unexpectedly.
            if magnitude < stableTh {
                if lastStableAccelDate == nil { lastStableAccelDate = now }
                if let s = lastStableAccelDate, now.timeIntervalSince(s) > 2.0 {
                    motionState = .stable
                    lastStableAccelDate = nil
                }
            } else {
                lastStableAccelDate = nil
            }

        case .moving:
            // Legacy case — never reached. Map back to stable.
            motionState = .stable
        }
    }
}
