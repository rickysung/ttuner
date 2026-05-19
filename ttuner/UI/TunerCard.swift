import SwiftUI

/// Compact top tuner — note name + cents inside a recessed LCD-style
/// readout, with a tick-mark strobe band underneath. The outer chrome
/// stays glassmorphic so the card still reads as one of the floating
/// glass surfaces, but the actual information lives on its own dark
/// inset panel that feels like a small hardware tuner display.
struct TunerCard: View {
    @Bindable var state: AppState

    var body: some View {
        GlassCard(cornerRadius: 22, density: 0.35) {
            VStack(spacing: 10) {
                lcdPanel
                strobeBand
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 170, height: 124)
    }

    // MARK: - LCD readout

    private var lcdPanel: some View {
        let hasReading = state.tuner.reading != nil
        let label = state.tuner.reading?.label ?? "—"
        let cents = state.tuner.reading?.cents ?? 0
        let f0 = state.tuner.current?.f0 ?? 0
        let mag = abs(cents)
        let centsColor: Color = !hasReading ? Color.white.opacity(0.28)
            : mag < 5 ? Color.stable
            : mag < 20 ? Color(red: 1.0, green: 0.72, blue: 0.25)
            : Color(red: 1.0, green: 0.40, blue: 0.40)
        let noteColor: Color = !hasReading ? Color.white.opacity(0.55)
            : state.tuner.stable ? Color(red: 0.55, green: 0.85, blue: 1.0)
            : Color.white.opacity(0.95)
        let centsText = hasReading ? String(format: "%+03.0f¢", cents) : "—¢"
        let hzText = hasReading
            ? (f0 >= 1000 ? String(format: "%.0f Hz", f0)
                          : String(format: "%.1f Hz", f0))
            : "— Hz"

        return ZStack {
            // Recessed display surface — dark panel inside the glass.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.42))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    LinearGradient(colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.02)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6
                )

            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .font(.system(size: 36, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(noteColor)
                        .shadow(color: state.tuner.stable
                                ? Color.stable.opacity(0.55)
                                : .clear,
                                radius: 5)
                    Text(centsText)
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(centsColor)
                        .shadow(color: state.tuner.stable
                                ? centsColor.opacity(0.6) : .clear,
                                radius: 3)
                }
                Text(hzText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 64)
        .padding(.horizontal, 10)
    }

    // MARK: - Strobe band

    /// Tick-mark band from −50¢ to +50¢. Majors every 10¢, minors every 2¢.
    /// The needle is a single hair-thin line that snaps via a spring.
    private var strobeBand: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cents = state.tuner.reading?.cents ?? 0
            let clamped = max(CGFloat(-50), min(CGFloat(50), CGFloat(cents)))
            let needleX = (clamped + 50) / 100 * w
            let stableColor = Color.stable

            ZStack(alignment: .topLeading) {
                // Etched baseline that the ticks sit on.
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: w, height: 0.6)
                    .offset(y: 14)
                ForEach(stride(from: -50, through: 50, by: 2).map { $0 }, id: \.self) { i in
                    let x = CGFloat(i + 50) / 100 * w
                    let isMajor = (i % 10 == 0)
                    let isCenter = (i == 0)
                    Rectangle()
                        .fill(Color.white.opacity(isCenter ? 0.85
                                                  : isMajor ? 0.55 : 0.22))
                        .frame(width: isCenter ? 1.4 : (isMajor ? 1.0 : 0.7),
                               height: isCenter ? 14 : (isMajor ? 9 : 4))
                        .offset(x: x - 0.5, y: 0)
                }
                // Needle.
                Rectangle()
                    .fill(state.tuner.stable ? stableColor : Color.white)
                    .frame(width: 1.6, height: 18)
                    .shadow(color: (state.tuner.stable ? stableColor : Color.white)
                                .opacity(0.6), radius: 3)
                    .offset(x: needleX - 0.8, y: -2)
                    .animation(.spring(response: 0.20, dampingFraction: 0.75),
                               value: needleX)
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 14)
    }
}
