import Foundation

struct NoteReading: Equatable {
    let name: String
    let octave: Int
    let cents: Double
    let midi: Int

    var label: String { "\(name)\(octave)" }
}

enum NoteMapper {
    private static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flats  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    static func map(f0: Float, referenceA: Double, transpose: Int, display: NoteDisplay) -> NoteReading? {
        guard f0 > 0 else { return nil }
        let midi = 69.0 + 12.0 * log2(Double(f0) / referenceA) - Double(transpose)
        guard midi.isFinite else { return nil }
        let nearest = Int(midi.rounded())
        let cents = (midi - Double(nearest)) * 100.0
        let names = display == .sharp ? sharps : flats
        let idx = ((nearest % 12) + 12) % 12
        let name = names[idx]
        let octave = nearest / 12 - 1
        return NoteReading(name: name, octave: octave, cents: cents, midi: nearest)
    }
}
