import SwiftUI

// MARK: - Shared brand color
//
// `stable` is the "in-tune blue" used everywhere — tuner readout glow,
// active strings, paywall accents, Pro badges, drone indicator. One
// authoritative definition so a future brand tweak stays in one file.

extension Color {
    /// Primary brand accent — the colour the app uses to say
    /// "this is good / locked-in / Pro / active". Matches the
    /// stable-pitch hue that lights up the tuner needle.
    static let stable = Color(red: 0.32, green: 0.70, blue: 1.0)
}

// MARK: - Reusable UI atoms

/// Small "Pro" lock chip used wherever a free user sees an
/// otherwise-available control that's gated behind the paywall.
struct ProBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Pro")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(Color.stable)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color.stable.opacity(0.18), in: Capsule())
    }
}

/// Compact +/- stepper button used by metronome, drone, custom-
/// tuning, and similar panels. Disabled state dims both the icon
/// and the background so the affordance is unambiguous.
struct StepperBtn: View {
    let systemName: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.25))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(enabled ? 0.12 : 0.04), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
