import SwiftUI

/// Soft, non-interactive screen-edge glow that signals "too quiet" (yellow)
/// or "too loud" (red). Designed to be readable in a glance without text.
struct LoudnessGlowOverlay: View {
    let level: Float      // 0..1 intensity
    let sign: Float       // -1 too quiet, +1 too loud, 0 neutral

    var body: some View {
        if level <= 0 || sign == 0 {
            Color.clear
        } else {
            GeometryReader { geo in
                let color: Color = sign < 0 ? Color.yellow.opacity(Double(level) * 0.35) : Color.red.opacity(Double(level) * 0.35)
                LinearGradient(
                    gradient: Gradient(colors: [color, .clear]),
                    startPoint: .topLeading,
                    endPoint: .center
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(color, lineWidth: 18)
                        .blur(radius: 14)
                        .blendMode(.plusLighter)
                        .padding(-12)
                )
            }
            .ignoresSafeArea()
        }
    }
}
