import SwiftUI

/// Always-visible "now playing" chip that lives below the tuner card.
/// Shows the current displayed BPM (which tracks Speed Trainer's climb
/// while the metronome is running) and a compact accent-pattern read-
/// out so the user knows the time signature at a glance even when the
/// metronome panel is closed. Tap opens the panel for full controls.
struct MetronomeStatusChip: View {
    @Bindable var state: AppState
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                bpmReadout
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 0.6, height: 14)
                accentDots
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    private var bpmReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            // Small running indicator — filled when playing, hollow
            // when stopped — gives the chip a tiny live/state cue
            // without taking horizontal space.
            Circle()
                .fill(state.metronome.isPlaying
                      ? Color.stable
                      : Color.white.opacity(0.25))
                .frame(width: 5, height: 5)
                .padding(.trailing, 2)
            Text("\(Int(state.metronome.displayBPM.rounded()))")
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("BPM")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Mirror of the accent-strength row in MetronomePanel, with one
    /// dot lit at a time when the metronome is playing. The lit dot
    /// advances via TimelineView anchored at `barStartDate` so we
    /// don't need a per-beat push from the engine.
    @ViewBuilder
    private var accentDots: some View {
        let n = max(1, state.metronome.timeSignature.numerator)
        let pattern = state.metronome.accentPattern
        if let pb = state.metronomePlaybackState, pb.bpm > 0 {
            let secsPerBeat = 60.0 / pb.bpm
            TimelineView(.periodic(from: pb.barStartDate, by: secsPerBeat)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(pb.barStartDate)
                let beat = max(0, Int(elapsed / secsPerBeat)) % max(1, n)
                dotsRow(n: n, pattern: pattern, currentBeat: beat)
                    .transaction { $0.animation = nil }
            }
        } else {
            dotsRow(n: n, pattern: pattern, currentBeat: -1)
        }
    }

    private func dotsRow(n: Int, pattern: [Accent], currentBeat: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<n, id: \.self) { i in
                let accent = i < pattern.count ? pattern[i] : Accent.normal
                let isCurrent = i == currentBeat
                Circle()
                    .fill(isCurrent ? Color.white : dotColor(accent: accent))
                    .frame(width: isCurrent ? 6 : 4.5,
                           height: isCurrent ? 6 : 4.5)
                    .shadow(color: isCurrent ? Color.white.opacity(0.6) : .clear,
                            radius: 2)
            }
        }
    }

    private func dotColor(accent: Accent) -> Color {
        switch accent {
        case .accent: return Color.stable
        case .normal: return Color.white.opacity(0.80)
        case .soft:   return Color.white.opacity(0.45)
        case .off:    return Color.white.opacity(0.18)
        }
    }
}
