import Foundation
import Metal

/// A swappable bundle of fragment shaders that defines the look of the
/// emitter, the particle cloud, and (optionally) a background pass.
///
/// Vertex stages stay shared — only the *appearance* changes between
/// themes. Physics and gameplay parameters live elsewhere (in the
/// renderer / particle system); a theme is purely visual.
///
/// To add a new theme:
///   1. Write `fs_emitter_<name>` and `fs_particle_<name>` (and
///      optionally `fs_background_<name>`) in `Shaders.metal`.
///   2. Append a `static let <name>` factory below.
///   3. Pass it to `SpectrogramRenderer.applyTheme(_:)`.
struct VisualTheme {
    let id: String
    /// Fullscreen fragment painted before everything else. `nil` ⇒ the
    /// renderer just clears with `clearColor` (cheaper, matches Flame).
    let backgroundFragment: String?
    let emitterFragment: String
    let particleFragment: String
    /// Color used when there is no background fragment — also the load
    /// clear behind any transparent background fragment.
    let clearColor: MTLClearColor

    static let flame = VisualTheme(
        id: "flame",
        backgroundFragment: nil,
        emitterFragment: "fs_emitter_flame",
        particleFragment: "fs_particle_flame",
        // Same near-black with the slightest cool tint as the pre-theme
        // code — keeping it identical so the Flame visual is unchanged.
        clearColor: MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
    )
}

extension VisualTheme: Equatable {
    /// Identity is fine for theme comparison — same id means same look.
    /// MTLClearColor is a C struct without auto-Equatable, so we'd need
    /// hand-written comparison if we ever wanted full structural equality.
    static func == (lhs: VisualTheme, rhs: VisualTheme) -> Bool {
        lhs.id == rhs.id
    }
}
