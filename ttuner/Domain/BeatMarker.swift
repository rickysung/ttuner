import Foundation

struct BeatMarker: Equatable {
    let hostTime: UInt64
    let accent: Accent
    let trackId: UInt8
    let bpm: Double
}
