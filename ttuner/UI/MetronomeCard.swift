import SwiftUI

struct MetronomeCard: View {
    @Bindable var state: AppState
    var onShowSheet: () -> Void

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                Button(action: togglePlay) {
                    Image(systemName: state.metronome.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.metronome.isPlaying ? "Stop metronome" : "Start metronome")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(state.metronome.bpm.rounded()))")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("BPM").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(state.metronome.timeSignature.label)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        accentDots
                    }
                }
                Spacer(minLength: 0)
                Button(action: onShowSheet) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .gesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in state.metronome.registerTap() })
        }
    }

    private func togglePlay() {
        if state.metronome.isPlaying { state.metronome.stop() }
        else { state.metronome.start() }
    }

    private var accentDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<state.metronome.accentPattern.count, id: \.self) { i in
                let a = state.metronome.accentPattern[i]
                Circle()
                    .fill(color(for: a))
                    .frame(width: a == .accent ? 8 : 6, height: a == .accent ? 8 : 6)
                    .opacity(a == .off ? 0.2 : 1)
            }
        }
    }

    private func color(for a: Accent) -> Color {
        switch a {
        case .accent: return .white
        case .normal: return Color.white.opacity(0.6)
        case .soft:   return Color.white.opacity(0.3)
        case .off:    return Color.white.opacity(0.1)
        }
    }
}
