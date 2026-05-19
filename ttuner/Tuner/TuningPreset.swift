import Foundation

/// A named set of target pitches that the tuner UI can highlight. The
/// `Chromatic` preset (empty `midiNotes`) is a sentinel meaning "no
/// instrument preset selected — just show the nearest semitone".
struct TuningPreset: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    /// MIDI numbers for each string. Ordered as they appear on the
    /// instrument (typically low → high). Empty for Chromatic.
    let midiNotes: [Int]

    var isChromatic: Bool { midiNotes.isEmpty }
}

enum TuningPresets {
    static let chromatic = TuningPreset(id: "chromatic",
                                         name: "Chromatic",
                                         midiNotes: [])

    // MARK: Guitar
    static let guitarStandard = TuningPreset(
        id: "guitar.standard", name: "Guitar — Standard",
        midiNotes: [40, 45, 50, 55, 59, 64] // E2 A2 D3 G3 B3 E4
    )
    static let guitarDropD = TuningPreset(
        id: "guitar.dropD", name: "Guitar — Drop D",
        midiNotes: [38, 45, 50, 55, 59, 64] // D2 A2 D3 G3 B3 E4
    )
    static let guitarOpenG = TuningPreset(
        id: "guitar.openG", name: "Guitar — Open G",
        midiNotes: [38, 43, 50, 55, 59, 62] // D2 G2 D3 G3 B3 D4
    )
    static let guitarHalfStepDown = TuningPreset(
        id: "guitar.halfStep", name: "Guitar — ½-step Down",
        midiNotes: [39, 44, 49, 54, 58, 63] // Eb2 Ab2 Db3 Gb3 Bb3 Eb4
    )
    static let guitarSeven = TuningPreset(
        id: "guitar.7string", name: "Guitar — 7-string",
        midiNotes: [35, 40, 45, 50, 55, 59, 64] // B1 E2 A2 D3 G3 B3 E4
    )

    // MARK: Bass
    static let bass4 = TuningPreset(
        id: "bass.4", name: "Bass — 4-string",
        midiNotes: [28, 33, 38, 43] // E1 A1 D2 G2
    )
    static let bass5 = TuningPreset(
        id: "bass.5", name: "Bass — 5-string",
        midiNotes: [23, 28, 33, 38, 43] // B0 E1 A1 D2 G2
    )
    static let bass6 = TuningPreset(
        id: "bass.6", name: "Bass — 6-string",
        midiNotes: [23, 28, 33, 38, 43, 48] // B0 E1 A1 D2 G2 C3
    )

    // MARK: Other strings
    static let ukulele = TuningPreset(
        id: "ukulele.gcea", name: "Ukulele — GCEA",
        midiNotes: [67, 60, 64, 69] // G4 C4 E4 A4 (high-G reentrant)
    )
    static let mandolin = TuningPreset(
        id: "mandolin", name: "Mandolin",
        midiNotes: [55, 62, 69, 76] // G3 D4 A4 E5
    )
    static let violin = TuningPreset(
        id: "violin", name: "Violin",
        midiNotes: [55, 62, 69, 76] // G3 D4 A4 E5
    )
    static let viola = TuningPreset(
        id: "viola", name: "Viola",
        midiNotes: [48, 55, 62, 69] // C3 G3 D4 A4
    )
    static let cello = TuningPreset(
        id: "cello", name: "Cello",
        midiNotes: [36, 43, 50, 57] // C2 G2 D3 A3
    )
    static let banjo = TuningPreset(
        id: "banjo", name: "Banjo — gDGBD",
        midiNotes: [67, 50, 55, 59, 62] // g4 D3 G3 B3 D4
    )

    static let all: [TuningPreset] = [
        chromatic,
        guitarStandard, guitarDropD, guitarOpenG,
        guitarHalfStepDown, guitarSeven,
        bass4, bass5, bass6,
        ukulele, mandolin,
        violin, viola, cello,
        banjo
    ]

    static func find(id: String) -> TuningPreset {
        all.first { $0.id == id } ?? chromatic
    }
}
