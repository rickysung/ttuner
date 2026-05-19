import SwiftUI

/// Glassmorphic surface — translucent enough that the spectrogram /
/// particle field reads through clearly, but with a hairline rim and a
/// subtle interior gradient to keep the silhouette legible.
struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 18
    /// 0 = whisper-thin glass (lets background show through almost fully).
    /// 1 = denser glass (closer to the original look).
    var density: CGFloat = 0.45
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    // System blur as the base — keeps content underneath
                    // readable even with a low fill alpha.
                    VisualEffectBlur(style: scheme == .dark
                                     ? .systemUltraThinMaterialDark
                                     : .systemUltraThinMaterialLight)
                        .opacity(density)
                    // Soft top-to-bottom interior tint for the "glass" feel
                    // without darkening the spectrogram.
                    LinearGradient(
                        colors: [Color.white.opacity(0.10 * density),
                                 Color.white.opacity(0.02 * density)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                // Rim highlight — what makes a translucent panel still
                // read as a defined surface.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.30),
                                     Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            )
            .shadow(color: .black.opacity(0.20), radius: 18, x: 0, y: 6)
    }
}
