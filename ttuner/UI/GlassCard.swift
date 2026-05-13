import SwiftUI

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    VisualEffectBlur(style: scheme == .dark
                                     ? .systemUltraThinMaterialDark
                                     : .systemUltraThinMaterialLight)
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    }
}
