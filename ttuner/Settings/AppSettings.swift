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
    var colormap: ColormapKind = .monoBlue
    var dbFloor: Float = -90
    var dbCeil: Float = 0
    var zoomMinHz: Float = 50
    var zoomMaxHz: Float = 4000

    var referenceA: Double = 440.0
    var transpose: Int = 0
    var stabilityCents: Float = 5
    var noteDisplay: NoteDisplay = .sharp

    var defaultBPM: Double = 120
    var defaultTimeSignature: TimeSignature = .fourFour
    var clickSound: String = "wood"
    var countInBars: Int = 0

    var timelineSeconds: Int = 600

    var autoTuneIn: Bool = true
    var silenceAwarePause: Bool = true
    var silenceThresholdDb: Float = -55
    var silenceSeconds: Double = 15
    var stableDetection: Bool = true
    var centTrail: Bool = true
    var intonationHeatmap: Bool = true
    var loudnessGlow: Bool = false

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
