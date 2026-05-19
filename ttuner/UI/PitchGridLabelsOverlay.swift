import SwiftUI

/// Floating note-name labels that sit on top of the shader-drawn pitch
/// grid. The renderer publishes `cameraSemitone` and `semitoneSpacing`
/// through the bridge every frame; `TimelineView(.animation)` re-evaluates
/// the body each refresh so positions stay locked to the moving lines.
///
/// We deliberately use ZStack + `.position` instead of Canvas — Canvas's
/// drawing closure has its own dependency tracker that doesn't notice
/// changes to non-`@Published` bridge fields, so labels would freeze.
/// Re-evaluating a plain SwiftUI tree per timeline tick avoids that
/// entire class of bug.
struct PitchGridLabelsOverlay: View {
    @ObservedObject var bridge: SpectrogramBridge
    let transpose: Int
    let noteDisplay: NoteDisplay

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                // Touch context.date so SwiftUI keeps re-evaluating the
                // body on every tick — without it the diff can stabilize
                // and stop layout updates when no @Published changes.
                let _ = context.date
                let cam = bridge.currentCameraSemitone
                let spacing = max(0.001, bridge.currentSemitoneSpacing)
                let w = geo.size.width
                let baseY = geo.size.height * 0.50
                let halfRange = 1.0 / Double(spacing)
                let kStart = Int((Double(cam) - halfRange - 1).rounded(.down))
                let kEnd   = Int((Double(cam) + halfRange + 1).rounded(.up))

                ZStack(alignment: .topLeading) {
                    ForEach(kStart...kEnd, id: \.self) { k in
                        let xNDC = Double(Float(k) - cam) * Double(spacing)
                        let x = (xNDC + 1.0) * 0.5 * Double(w)
                        let edge = abs((x / Double(w)) - 0.5) * 2.0
                        let baseAlpha = max(0, 1.0 - edge * 0.85)
                        let kMod = ((k % 12) + 12) % 12
                        let isNatural = ((1 << kMod) & 0xAD5) != 0
                        let alpha = baseAlpha * (isNatural ? 0.70 : 0.30)
                        if alpha > 0.02 && x > -40 && x < Double(w) + 40 {
                            Text(NoteMapper.label(forMidi: k + transpose,
                                                  display: noteDisplay))
                                .font(.system(size: isNatural ? 12 : 10,
                                              weight: isNatural ? .semibold : .regular,
                                              design: .rounded))
                                .foregroundStyle(Color.white.opacity(alpha))
                                .position(x: CGFloat(x), y: baseY)
                        }
                    }
                }
            }
        }
    }
}
