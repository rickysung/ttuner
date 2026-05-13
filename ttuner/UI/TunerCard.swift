import SwiftUI

struct TunerCard: View {
    @Bindable var state: AppState

    var body: some View {
        GlassCard {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(state.tuner.reading?.label ?? "—")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(minWidth: 84, alignment: .leading)
                        .shadow(color: state.tuner.stable ? .green.opacity(0.7) : .clear, radius: 8)
                    centsLabel
                    Spacer(minLength: 0)
                    transposeBadge
                }
                gauge
                refRow
            }
        }
    }

    private var centsLabel: some View {
        let cents = state.tuner.reading?.cents ?? 0
        let mag = abs(cents)
        let color: Color = mag < 5 ? .green : (mag < 20 ? .orange : .red)
        let txt = state.tuner.reading == nil ? "—¢" : String(format: "%+.1f¢", cents)
        return Text(txt)
            .font(.system(.title3, design: .rounded, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var transposeBadge: some View {
        let label = "A=\(Int(state.settings.referenceA))  T\(state.settings.transpose >= 0 ? "+" : "")\(state.settings.transpose)"
        return Text(label)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var gauge: some View {
        let cents = CGFloat(min(50, max(-50, state.tuner.reading?.cents ?? 0)))
        return GeometryReader { geo in
            let w = geo.size.width
            let centerX = w / 2
            let dotX = centerX + (cents / 50.0) * (w / 2 - 6)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 4)
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 2, height: 12)
                    .offset(x: centerX - 1, y: -4)
                Circle()
                    .fill(state.tuner.stable ? Color.green : Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: dotX - 5, y: -3)
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: dotX)
            }
        }
        .frame(height: 14)
    }

    private var refRow: some View {
        HStack(spacing: 12) {
            Stepper(value: $state.settings.referenceA, in: 415...460, step: 1) {
                Text("Ref \(Int(state.settings.referenceA))Hz")
                    .font(.caption)
            }
            .labelsHidden()
            Text("Ref \(Int(state.settings.referenceA))Hz").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Stepper(value: $state.settings.transpose, in: -12...12) {
                Text("T\(state.settings.transpose)")
            }
            .labelsHidden()
            Text("T \(state.settings.transpose)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
