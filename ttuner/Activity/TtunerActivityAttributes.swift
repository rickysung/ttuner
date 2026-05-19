import ActivityKit
import Foundation

/// State shared between the main app and the widget extension that drives
/// the Live Activity for the tuner + metronome. Kept intentionally flat
/// and small — Live Activity payloads are size-capped and updated often.
///
/// Metronome representation is **time-anchored**, not beat-counted: the
/// app pushes `barStartDate` + `bpm` once when playback (or settings)
/// changes, and the widget's `TimelineView(.periodic(...))` ticks the
/// lit beat dot on its own without further pushes. This is the only way
/// to avoid iOS Live Activity update-rate throttling at metronome speeds.
struct TtunerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // MARK: Tuner
        var isTunerActive: Bool
        /// e.g. "A4", "F♯3". `nil` when there is no recent reading.
        var noteLabel: String?
        /// Deviation from the nearest semitone in cents, clamped to ±50.
        /// Quantised to whole cents by the coordinator to suppress
        /// detector noise from churning Live Activity updates.
        var cents: Double
        /// True once the reading has held inside the tolerance band.
        var isStable: Bool

        // MARK: Metronome
        var isMetronomePlaying: Bool
        /// Current tempo in beats per minute.
        var bpm: Int
        /// Number of beats per bar, e.g. 4 for 4/4.
        var beatsPerBar: Int
        /// Wall-clock time when beat 0 of the current bar fired (or will
        /// fire). The widget's TimelineView extrapolates the lit beat
        /// from `(Date.now - barStartDate) / secondsPerBeat % beatsPerBar`,
        /// so this single anchor + bpm is enough to animate indefinitely
        /// without further pushes. `nil` while not playing.
        var barStartDate: Date?
        /// Per-beat accent flags, length == beatsPerBar. The lit dot
        /// colors blue when its corresponding entry is `true`, white
        /// otherwise.
        var accents: [Bool]

        static let idle = ContentState(
            isTunerActive: false,
            noteLabel: nil,
            cents: 0,
            isStable: false,
            isMetronomePlaying: false,
            bpm: 120,
            beatsPerBar: 4,
            barStartDate: nil,
            accents: [true, false, false, false]
        )
    }
}
