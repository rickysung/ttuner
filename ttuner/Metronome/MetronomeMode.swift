import Foundation

/// Top-level mode that determines how the scheduler emits beats.
enum MetronomeMode: Equatable, Codable {
    /// Single track at constant BPM.
    case simple
    /// Two tracks running at the same bar boundary. Primary is the configured
    /// time signature; secondary fires `secondaryBeats` evenly-spaced clicks
    /// within the same bar duration (e.g. 3 over 2 / 5 over 4).
    case polyrhythm(secondaryBeats: Int)
    /// Linear BPM ramp from `startBPM` → `endBPM` over `bars` measures.
    case gradual(startBPM: Double, endBPM: Double, bars: Int)
    /// Practice mode: starts at `startBPM`, steps +5 BPM every
    /// `barsPerStep` bars, and clamps once `endBPM` is reached. Used
    /// to gradually build playing speed toward a target tempo.
    case speedTrainer(startBPM: Double, endBPM: Double, barsPerStep: Int)

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .polyrhythm(let n): return "Polyrhythm \(n)"
        case .gradual(let s, let e, let b): return "Gradual \(Int(s))→\(Int(e)) / \(b) bars"
        case .speedTrainer(let s, let e, let bps): return "Speed \(Int(s))→\(Int(e)) / \(bps)b"
        }
    }
}

enum BeatTrack: UInt8 {
    case primary = 0
    case secondary = 1
    case subdivision = 2
    case countIn = 3
}
