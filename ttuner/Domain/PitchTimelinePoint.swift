import Foundation

/// A single pitch-detection sample plotted on the vertical timeline.
///
/// `semitone` is a continuous MIDI value (60 = C4, 69 = A4). The display
/// rounds this to render the dot's X position relative to the smoothed camera
/// semitone — the integer part picks a reference column, the fractional part
/// is the cents deviation.
struct PitchTimelinePoint {
    let hostTime: UInt64
    let semitone: Float
    let clarity: Float
    let rmsDb: Float
}
