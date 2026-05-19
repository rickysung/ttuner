import SwiftUI

/// Bottom slide-up metronome panel — replaces both `MetronomeCard` and the
/// modal `MetronomeSheet`. Two sections:
///   • upper: time signature picker + per-beat accent strength buttons.
///   • lower: play/stop, BPM display + ± step, matte dotted tap-tempo pad.
struct MetronomePanel: View {
    @Bindable var state: AppState
    var onClose: () -> Void

    private let timeSignatures: [TimeSignature] = [.twoFour, .threeFour, .fourFour, .sixEight]
    private let allowedDenominators: [Int] = [1, 2, 4, 8, 16, 32]
    @State private var showCustomEditor: Bool = false

    var body: some View {
        GlassCard(cornerRadius: 24, density: 0.40) {
            VStack(spacing: 14) {
                header
                Divider().background(Color.white.opacity(0.10))
                accentSection
                Divider().background(Color.white.opacity(0.10))
                practiceSection
                Divider().background(Color.white.opacity(0.10))
                transportSection
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 14)
    }

    // MARK: Practice section
    //
    // Speed Trainer: every N bars, BPM bumps by X. The label collapses
    // to "Speed +5 / 4b" so the row fits on one line. The toggle dot
    // dims the whole row when off so the steppers don't draw the eye.
    //
    // Silence Trainer: every M+1 bars, the last bar is fully silent
    // (audio + visual marker). Stepper picks M.

    private var practiceSection: some View {
        HStack(spacing: 10) {
            // Pro-gated. Free users get a tap that opens the paywall
            // instead of toggling the bound setting on.
            if state.pro.isPro {
                toggleDot(isOn: $state.settings.speedTrainerEnabled)
            } else {
                Button {
                    state.showPaywall = true
                } label: {
                    ZStack {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 26, height: 16)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.stable)
                    }
                }
                .buttonStyle(.plain)
            }
            speedTrainerGlyph
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                // Row 1: start BPM → end BPM. The trainer always climbs
                // in +5 BPM steps so we only need these two anchors.
                HStack(spacing: 6) {
                    stepperGroup(value: Int(state.settings.speedTrainerStartBPM),
                                 min: 40, max: 230,
                                 active: state.settings.speedTrainerEnabled,
                                 onMinus: {
                                     let new = max(40, state.settings.speedTrainerStartBPM - 5)
                                     state.settings.speedTrainerStartBPM = new
                                     if state.settings.speedTrainerEndBPM <= new {
                                         state.settings.speedTrainerEndBPM = min(240, new + 5)
                                     }
                                 },
                                 onPlus: {
                                     let new = min(230, state.settings.speedTrainerStartBPM + 5)
                                     state.settings.speedTrainerStartBPM = new
                                     if state.settings.speedTrainerEndBPM <= new {
                                         state.settings.speedTrainerEndBPM = min(240, new + 5)
                                     }
                                 })
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    stepperGroup(value: Int(state.settings.speedTrainerEndBPM),
                                 min: 45, max: 240,
                                 active: state.settings.speedTrainerEnabled,
                                 onMinus: {
                                     let floor = state.settings.speedTrainerStartBPM + 5
                                     state.settings.speedTrainerEndBPM = max(floor, state.settings.speedTrainerEndBPM - 5)
                                 },
                                 onPlus: {
                                     state.settings.speedTrainerEndBPM = min(240, state.settings.speedTrainerEndBPM + 5)
                                 })
                }
                // Row 2: "every N bars" — spelled out naturally so the
                // unit doesn't ride on a cryptic "b" suffix.
                HStack(spacing: 6) {
                    Text("every")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    stepperGroup(value: state.settings.speedTrainerBarsPerStep,
                                 min: 1, max: 32,
                                 active: state.settings.speedTrainerEnabled,
                                 onMinus: {
                                     state.settings.speedTrainerBarsPerStep = max(1, state.settings.speedTrainerBarsPerStep - 1)
                                 },
                                 onPlus: {
                                     state.settings.speedTrainerBarsPerStep = min(32, state.settings.speedTrainerBarsPerStep + 1)
                                 })
                    Text(state.settings.speedTrainerBarsPerStep == 1 ? "bar" : "bars")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opacity(state.settings.speedTrainerEnabled ? 1.0 : 0.55)
        .padding(.horizontal, 6)
    }

    /// Five capsule bars stepping upward — visual shorthand for
    /// "tempo climbs over time" without an English label.
    private var speedTrainerGlyph: some View {
        let on = state.settings.speedTrainerEnabled
        let tint: Color = on
            ? Color.stable
            : Color.white.opacity(0.40)
        return HStack(alignment: .bottom, spacing: 1.8) {
            ForEach(0..<5, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: 2.5, height: CGFloat(4 + i * 2))
            }
        }
        .frame(height: 14)
    }

    private func stepperGroup(value: Int,
                               prefix: String = "",
                               suffix: String = "",
                               min lo: Int,
                               max hi: Int,
                               active: Bool,
                               onMinus: @escaping () -> Void,
                               onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text("\(prefix)\(value)\(suffix)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(active ? .primary : .secondary)
                .frame(minWidth: 26)
            stepperBtn(system: "minus", enabled: value > lo, action: onMinus)
            stepperBtn(system: "plus", enabled: value < hi, action: onPlus)
        }
    }

    private func toggleDot(isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn.wrappedValue
                          ? Color.stable.opacity(0.85)
                          : Color.white.opacity(0.15))
                    .frame(width: 26, height: 16)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: isOn.wrappedValue ? 5 : -5)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.20, dampingFraction: 0.85),
                   value: isOn.wrappedValue)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Metronome")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Accent section

    private var accentSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(timeSignatures, id: \.label) { sig in
                    let selected = state.metronome.timeSignature == sig && !showCustomEditor
                    Button(sig.label) {
                        showCustomEditor = false
                        state.metronome.timeSignature = sig
                        state.metronome.accentPattern = TimeSignature.defaultAccentPattern(for: sig)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                                in: Capsule())
                }
                let isCustom = !timeSignatures.contains(state.metronome.timeSignature)
                Button {
                    showCustomEditor.toggle()
                } label: {
                    Image(systemName: showCustomEditor ? "chevron.up" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle((showCustomEditor || isCustom) ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background((showCustomEditor || isCustom) ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if showCustomEditor {
                customEditor
            }

            // Per-beat accent strength — tap to cycle (off/soft/normal/accent).
            // Width adapts to bar count so 13/8 still fits the screen.
            accentBars
        }
    }

    private var accentBars: some View {
        GeometryReader { geo in
            let count = max(1, state.metronome.accentPattern.count)
            let spacing: CGFloat = 4
            let slot = max(8, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let barW = min(slot, 24)
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let a = state.metronome.accentPattern[i]
                    Button {
                        let next = a.next()
                        state.metronome.accentPattern[i] = next
                        // Audition the new strength so the user hears what
                        // their tap will sound like under the metronome.
                        state.metronome.previewClick(accent: next)
                    } label: {
                        AccentBar(level: a, slotWidth: slot, barWidth: barW)
                    }
                    .buttonStyle(.plain)
                    .frame(width: slot)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 30)
    }

    /// Custom time-signature editor: pick any numerator 1–13 and a power-of-two
    /// denominator. Changes reset the accent pattern with the leading downbeat
    /// emphasized, matching the preset behavior.
    private var customEditor: some View {
        let numBinding = Binding<Int>(
            get: { state.metronome.timeSignature.numerator },
            set: { newValue in
                var sig = state.metronome.timeSignature
                sig.numerator = max(1, min(13, newValue))
                state.metronome.timeSignature = sig
                state.metronome.accentPattern = TimeSignature.defaultAccentPattern(for: sig)
            }
        )
        let denBinding = Binding<Int>(
            get: { state.metronome.timeSignature.denominator },
            set: { newValue in
                var sig = state.metronome.timeSignature
                sig.denominator = newValue
                state.metronome.timeSignature = sig
                state.metronome.accentPattern = TimeSignature.defaultAccentPattern(for: sig)
            }
        )
        return HStack(spacing: 14) {
            sigStepper(value: numBinding.wrappedValue,
                       canDecrement: numBinding.wrappedValue > 1,
                       canIncrement: numBinding.wrappedValue < 13,
                       label: "Beats",
                       onMinus: { numBinding.wrappedValue -= 1 },
                       onPlus:  { numBinding.wrappedValue += 1 })
            Text("\(numBinding.wrappedValue) / \(denBinding.wrappedValue)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 56)
            sigStepper(value: denBinding.wrappedValue,
                       canDecrement: allowedDenominators.firstIndex(of: denBinding.wrappedValue).map { $0 > 0 } ?? false,
                       canIncrement: allowedDenominators.firstIndex(of: denBinding.wrappedValue).map { $0 < allowedDenominators.count - 1 } ?? false,
                       label: "Note",
                       onMinus: { cycleDenominator(denBinding, by: -1) },
                       onPlus:  { cycleDenominator(denBinding, by: +1) })
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cycleDenominator(_ binding: Binding<Int>, by delta: Int) {
        guard let idx = allowedDenominators.firstIndex(of: binding.wrappedValue) else { return }
        let next = idx + delta
        guard next >= 0 && next < allowedDenominators.count else { return }
        binding.wrappedValue = allowedDenominators[next]
    }

    /// Compact ±-style stepper with a centered numeric readout. Matches the
    /// visual weight of the transport BPM stepper for consistency.
    private func sigStepper(value: Int,
                            canDecrement: Bool, canIncrement: Bool,
                            label: String,
                            onMinus: @escaping () -> Void,
                            onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            stepperBtn(system: "minus", enabled: canDecrement, action: onMinus)
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30)
            stepperBtn(system: "plus", enabled: canIncrement, action: onPlus)
        }
    }

    private func stepperBtn(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.25))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(enabled ? 0.12 : 0.04), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Transport section

    private var transportSection: some View {
        HStack(spacing: 14) {
            Button(action: togglePlay) {
                Image(systemName: state.metronome.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
            }
            .buttonStyle(.plain)

            // BPM readout — large, no buttons below; the ± now lives next
            // to the tap pad on the right so it's reachable with the same
            // thumb that taps tempo.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(state.metronome.displayBPM.rounded()))")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Right cluster: stacked − / + flush against the tap pad.
            VStack(spacing: 6) {
                bpmStep(+1)
                bpmStep(-1)
            }

            TapTempoPad { state.metronome.registerTap() }
        }
    }

    private func bpmStep(_ delta: Int) -> some View {
        Button {
            let next = max(30, min(260, state.metronome.bpm + Double(delta)))
            state.metronome.bpm = next
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 18)
                .background(Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func togglePlay() {
        if state.metronome.isPlaying { state.metronome.stop() }
        else { state.metronome.start() }
    }
}

/// Vertical accent strength bar — height encodes intensity.
/// `slotWidth` is the per-beat allotment (drives tap area), `barWidth` is
/// the visible bar width inside that slot. They diverge when many beats
/// crowd the row so the visual stays slim while taps remain reachable.
private struct AccentBar: View {
    let level: Accent
    var slotWidth: CGFloat = 24
    var barWidth: CGFloat = 24

    var body: some View {
        let h = barHeight
        let alpha = barAlpha
        let visibleBar = max(4, min(barWidth - 4, 12))
        VStack {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white.opacity(alpha))
                .frame(width: visibleBar, height: h)
        }
        .frame(width: slotWidth, height: 30)
        .contentShape(Rectangle())
    }

    private var barHeight: CGFloat {
        switch level {
        case .off:    return 4
        case .soft:   return 14
        case .normal: return 22
        case .accent: return 30
        }
    }
    private var barAlpha: Double {
        switch level {
        case .off:    return 0.18
        case .soft:   return 0.45
        case .normal: return 0.75
        case .accent: return 1.00
        }
    }
}

/// Matte dot-textured pad. Tap to register a tap-tempo beat.
private struct TapTempoPad: View {
    var onTap: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        Button {
            onTap()
            withAnimation(.easeOut(duration: 0.12)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.25)) { pulse = false }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                DotPattern()
                    .foregroundStyle(Color.white.opacity(0.30))
                Text("TAP")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 64, height: 44)
            .scaleEffect(pulse ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

/// Small dotted matrix used as the tap-pad texture.
private struct DotPattern: View {
    var spacing: CGFloat = 4
    var dotSize: CGFloat = 1.2

    var body: some View {
        Canvas { context, size in
            let cols = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            let dx = (size.width - CGFloat(cols - 1) * spacing) / 2
            let dy = (size.height - CGFloat(rows - 1) * spacing) / 2
            for r in 0..<rows {
                for c in 0..<cols {
                    let p = CGPoint(x: dx + CGFloat(c) * spacing,
                                    y: dy + CGFloat(r) * spacing)
                    let rect = CGRect(x: p.x - dotSize/2, y: p.y - dotSize/2,
                                      width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.55)))
                }
            }
        }
    }
}
