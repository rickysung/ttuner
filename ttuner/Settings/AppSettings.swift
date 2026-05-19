import Foundation

enum SessionAudioMode: String, Codable, CaseIterable {
    case measurement
    case voiceChat

    var label: String {
        switch self {
        case .measurement: return "측정 (Measurement)"
        case .voiceChat:   return "음성 친화 (Voice Chat)"
        }
    }
}

enum ColormapKind: String, Codable, CaseIterable {
    case viridis
    case magma
    case inferno
    case monoBlue

    var label: String {
        switch self {
        case .viridis:  return "Viridis"
        case .magma:    return "Magma"
        case .inferno:  return "Inferno"
        case .monoBlue: return "Mono Blue"
        }
    }
}

enum NoteDisplay: String, Codable, CaseIterable {
    case sharp, flat
}

enum MotionSensitivity: String, Codable, CaseIterable {
    case sensitive, normal, dull

    var stableThreshold: Double {
        switch self {
        case .sensitive: return 0.02
        case .normal:    return 0.03
        case .dull:      return 0.05
        }
    }

    var movingThreshold: Double {
        switch self {
        case .sensitive: return 0.10
        case .normal:    return 0.15
        case .dull:      return 0.25
        }
    }
}

struct AppSettings: Codable, Equatable {
    var sampleRatePreference: Double = 48_000
    var sessionMode: SessionAudioMode = .measurement
    var inputGain: Float = 1.0

    var fftSize: Int = 4096
    var hopSize: Int = 512
    var displayBins: Int = 512
    var colormap: ColormapKind = .magma
    var dbFloor: Float = -45
    var dbCeil: Float = 35
    // Orchestra range with a touch of margin on both sides.
    // Low: just under B0 (≈30.87 Hz, contrabass with extension).
    // High: a comfortable margin above piccolo C8 (≈4186 Hz) for overtones.
    var zoomMinHz: Float = 30
    var zoomMaxHz: Float = 6000

    var referenceA: Double = 440.0
    var transpose: Int = 0
    var stabilityCents: Float = 5
    var noteDisplay: NoteDisplay = .sharp
    /// Identifier of the active instrument tuning preset, e.g.
    /// `guitar.standard`. The `chromatic` sentinel disables the
    /// string-indicator row and keeps the tuner in pure chromatic mode.
    /// Custom user-defined tunings use ids prefixed with `custom.`.
    var tuningPresetId: String = "chromatic"

    /// User-defined alternate tunings. Pro feature — guarded at the
    /// editor level so non-Pro users never reach the save UI in the
    /// first place. Stored alongside the rest of the settings blob
    /// so they round-trip with the app's existing JSON persistence.
    var customTunings: [CustomTuning] = []

    /// When true, taps in the Pitch panel start a sustained drone
    /// instead of a one-shot reference tone. Pro feature — gated at
    /// the toggle level; the panel itself is free so users can hear
    /// what they'd be unlocking before paying.
    var droneModeEnabled: Bool = false

    var defaultBPM: Double = 120
    var defaultTimeSignature: TimeSignature = .fourFour
    var clickSound: String = "wood"
    var countInBars: Int = 0

    /// Practice option — when enabled, the engine runs in
    /// `.speedTrainer` mode stepping the BPM from `speedTrainerStartBPM`
    /// up to `speedTrainerEndBPM` in +5 BPM increments every
    /// `speedTrainerBarsPerStep` bars, then holding at the end value.
    /// Disabling reverts to `.simple`.
    var speedTrainerEnabled: Bool = false
    var speedTrainerStartBPM: Double = 60
    var speedTrainerEndBPM: Double = 120
    var speedTrainerBarsPerStep: Int = 4

    var timelineSeconds: Int = 600

    var autoTuneIn: Bool = false
    var silenceAwarePause: Bool = true
    var silenceThresholdDb: Float = -55
    var silenceSeconds: Double = 15
    var stableDetection: Bool = true
    var centTrail: Bool = false
    var intonationHeatmap: Bool = true
    var loudnessGlow: Bool = false

    /// Constant opacity of the volume bars (0 = invisible, 1 = solid).
    /// Bar length already tracks RMS — opacity stays put for readability.
    var volumeBarOpacity: Float = 0.70
    /// Strength of the in-shader spectrogram blur (0 = off, 1 = full 5-tap).
    var spectroBlur: Float = 1.0

    var movementAwarePause: Bool = true
    var motionSensitivity: MotionSensitivity = .normal
    var autoResume: Bool = false

    var hapticOnBeat: Bool = false
    var btLatencyCompensation: Bool = true
    var keepScreenOn: Bool = true
    var discreetModeAuto: Bool = true
    var reduceMotionOverride: Bool = false

    static let storageKey = "app.ttuner.settings.v1"

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.storageKey)
        }
    }
}
