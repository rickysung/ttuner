import Foundation

/// User-defined tuning saved in app settings. Materialised into a
/// `TuningPreset` at runtime so the rest of the tuning code path stays
/// preset-agnostic.
struct CustomTuning: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var midiNotes: [Int]

    /// Stable preset identifier — prefixed so the picker can recognise
    /// custom entries and offer "edit / delete" affordances on them.
    var presetId: String { "custom.\(id.uuidString)" }

    var asPreset: TuningPreset {
        TuningPreset(id: presetId, name: name, midiNotes: midiNotes)
    }

    /// Tag a preset id as belonging to the custom-tuning family.
    static func isCustomPresetId(_ id: String) -> Bool {
        id.hasPrefix("custom.")
    }
}

extension TuningPresets {
    /// Built-in presets plus the user's saved customs, ready for any
    /// picker. The Chromatic sentinel is always first. Customs appear
    /// after the built-ins so the most-used presets stay near the top
    /// of long menus.
    static func all(includingCustom customs: [CustomTuning]) -> [TuningPreset] {
        all + customs.map(\.asPreset)
    }

    /// Like `find(id:)` but also searches the supplied custom list.
    static func find(id: String, customs: [CustomTuning]) -> TuningPreset {
        if let custom = customs.first(where: { $0.presetId == id }) {
            return custom.asPreset
        }
        return find(id: id)
    }
}
