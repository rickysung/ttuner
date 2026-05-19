import SwiftUI

/// Row of string indicators shown beneath the main TunerCard whenever a
/// non-chromatic preset is active. Shares the same glass surface as
/// TunerCard so the two read as one component, and folds the active /
/// tuned states into a single underline (slate by default, bright blue
/// once verified in tune) instead of a separate checkmark glyph.
struct TuningStringRow: View {
    @Bindable var state: AppState
    /// Index of the pill the user just tapped, used to flash a brief
    /// "playing reference" highlight that's visually distinct from the
    /// live-pitch "active" highlight.
    @State private var playingIndex: Int? = nil

    var body: some View {
        let preset = state.selectedTuningPreset
        if preset.isChromatic {
            EmptyView()
        } else {
            GlassCard(cornerRadius: 14, density: 0.35) {
                HStack(spacing: 2) {
                    // Single dim speaker glyph quietly signals "this row
                    // makes sound when tapped" without dragging in a
                    // caption line. Sits flush left of the pills.
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.40))
                        .padding(.trailing, 4)

                    ForEach(Array(preset.midiNotes.enumerated()), id: \.offset) { idx, midi in
                        Button {
                            playReference(midi: midi, index: idx)
                        } label: {
                            pill(
                                label: NoteMapper.label(forMidi: midi,
                                                        display: state.settings.noteDisplay),
                                isActive: state.activeStringIndex == idx,
                                isTuned: state.tunedStringIndices.contains(idx),
                                isPlaying: playingIndex == idx
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func playReference(midi: Int, index: Int) {
        ReferenceTone.shared.play(midi: midi, referenceA: state.settings.referenceA)
        withAnimation(.easeOut(duration: 0.08)) {
            playingIndex = index
        }
        // Match the actual tone duration so the flash decays with the
        // sound rather than ahead of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeIn(duration: 0.25)) {
                if playingIndex == index { playingIndex = nil }
            }
        }
    }

    private func pill(label: String, isActive: Bool, isTuned: Bool, isPlaying: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .tracking(0.3)
                .foregroundStyle(textColor(active: isActive, tuned: isTuned, playing: isPlaying))
            // A single underline carries two pieces of info at once:
            // tuned strings turn bright blue, active stays a slate hint,
            // resting strings nearly invisible. No second glyph needed.
            Capsule(style: .continuous)
                .fill(underlineColor(active: isActive, tuned: isTuned))
                .frame(width: 14, height: 1.6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isPlaying ? Color.white.opacity(0.22)
                      : isActive ? stableColor.opacity(0.14)
                      : Color.clear)
        )
        .overlay(
            // Hairline outline — just enough to suggest each pill is a
            // discrete tappable element, fades out completely on the
            // active / playing pills where their own treatment takes
            // over.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(
                    (isActive || isPlaying) ? 0 : 0.10
                ), lineWidth: 0.6)
        )
        .shadow(color: isPlaying ? Color.white.opacity(0.4)
                      : isActive ? stableColor.opacity(0.45) : .clear,
                radius: 4)
    }

    private var stableColor: Color { Color.stable }

    private func textColor(active: Bool, tuned: Bool, playing: Bool) -> Color {
        if playing { return .white }
        if active { return stableColor }
        if tuned { return Color.white.opacity(0.85) }
        return .white.opacity(0.50)
    }

    private func underlineColor(active: Bool, tuned: Bool) -> Color {
        if tuned { return stableColor }
        if active { return Color.white.opacity(0.45) }
        return Color.white.opacity(0.10)
    }
}
