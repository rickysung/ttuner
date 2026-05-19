import SwiftUI
import StoreKit

/// Soft paywall — presented as a sheet whenever the user taps a Pro
/// feature. Each feature card carries a live SwiftUI preview that
/// mirrors the look of the actual in-app component, plus a short
/// concrete description. Closes with X / Maybe Later so the user can
/// dismiss without committing.
struct PaywallSheet: View {
    @Bindable var pro: ProStore
    var onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.06, green: 0.07, blue: 0.10),
                Color(red: 0.01, green: 0.01, blue: 0.02)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        titleBlock
                        VStack(spacing: 12) {
                            featureCard(
                                preview: AnyView(TuningStringsPreview()),
                                title: "Built-in & Custom Tunings",
                                body: "15 instrument presets plus your own alt tunings — DADGAD, drop C, save any."
                            )
                            featureCard(
                                preview: AnyView(DronePreview()),
                                title: "Drone Mode",
                                body: "Hold a reference pitch while you practice. Stays playing through PIP."
                            )
                            featureCard(
                                preview: AnyView(SpeedTrainerPreview()),
                                title: "Speed Trainer",
                                body: "Climb tempo automatically in +5 BPM steps. Set start, end, and pace."
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 12)
                }
                bottomBar
            }
        }
        .task { await pro.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text("ttuner Pro")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Everything you need, tuned deeper.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 4)
    }

    // MARK: - Feature card

    /// Two-row card: preview canvas on top (dark inset, fixed height
    /// so all three line up), title + body below.
    private func featureCard(preview: AnyView, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LinearGradient(colors: [
                    Color(red: 0.025, green: 0.030, blue: 0.045),
                    Color(red: 0.005, green: 0.008, blue: 0.020)
                ], startPoint: .top, endPoint: .bottom)
                preview
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(body)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let error = pro.purchaseError {
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }

            Button {
                Task { await pro.purchase() }
            } label: {
                Group {
                    if pro.isPurchasing {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text(buyButtonText)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    stableColor,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(pro.product == nil || pro.isPurchasing)

            HStack(spacing: 18) {
                Button("Restore Purchases") {
                    Task { await pro.restore() }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .disabled(pro.isPurchasing)

                Button("Maybe Later", action: onClose)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)

            Text("One-time purchase. No subscription. Restore on any device with the same Apple ID.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .padding(.top, 8)
    }

    private var buyButtonText: String {
        if let p = pro.product { return "Unlock for \(p.displayPrice)" }
        return "Unlock ttuner Pro"
    }

    private var stableColor: Color { Color.stable }
}

// MARK: - Feature previews
//
// All three previews are live SwiftUI views — no PNG assets needed.
// They mimic the look of the in-app component closely enough that the
// user recognises what they're buying, with a small TimelineView-driven
// animation so the card feels alive without distracting.

/// Cycles through a handful of named tunings — Standard, DADGAD,
/// Drop C, Open G — to sell the "built-in + custom" angle at a
/// glance. The string row underneath updates in sync.
private struct TuningStringsPreview: View {
    private let stableColor = Color.stable
    private let tunings: [(name: String, labels: [String])] = [
        ("Standard", ["E", "A", "D", "G", "B", "E"]),
        ("DADGAD",   ["D", "A", "D", "G", "A", "D"]),
        ("Drop C",   ["C", "G", "C", "F", "A", "D"]),
        ("Open G",   ["D", "G", "D", "G", "B", "D"])
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.6)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 1.6)
            let tuning = tunings[((step % tunings.count) + tunings.count) % tunings.count]
            VStack(spacing: 6) {
                Text(tuning.name)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(stableColor)
                    .contentTransition(.opacity)
                HStack(spacing: 5) {
                    ForEach(Array(tuning.labels.enumerated()), id: \.offset) { _, label in
                        pill(label: label)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
    }

    private func pill(label: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
            Capsule()
                .fill(stableColor.opacity(0.7))
                .frame(width: 12, height: 1.4)
        }
        .padding(.horizontal, 4)
    }
}

/// Sustained-tone visual — three slowly-expanding rings around a
/// waveform glyph, paired with a rotating drone-note caption. Slow
/// pacing because a drone is felt as continuous, not pulsed.
private struct DronePreview: View {
    private let stableColor = Color.stable
    private let notes = ["A4", "D4", "G3", "C4"]

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 3.0) / 3.0
            let noteIdx = Int(t / 3.0) % notes.count

            HStack(spacing: 14) {
                ZStack {
                    ForEach(0..<3, id: \.self) { ring in
                        let ringStart = Double(ring) * 0.30
                        let local = max(0, min(1, (cycle - ringStart) * 1.2))
                        Circle()
                            .stroke(stableColor.opacity((1 - local) * 0.55),
                                    lineWidth: 1.0)
                            .frame(
                                width: 22 + CGFloat(local) * 42,
                                height: 22 + CGFloat(local) * 42
                            )
                            .opacity(local > 0 && local < 1 ? 1 : 0)
                    }
                    Image(systemName: "waveform.path")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(stableColor)
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .heavy))
                        Text("\(notes[noteIdx]) drone")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(.white)
                    Text("Playing through PIP")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

/// Climbing-tempo readout — BPM ticks up 60→65→...→95, accompanied by
/// the same 5-bar climbing glyph that lives in `MetronomePanel`.
private struct SpeedTrainerPreview: View {
    private let stableColor = Color.stable

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 8
            let bpm = 60 + step * 5

            HStack(spacing: 14) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(stableColor)
                            .frame(width: 3.2, height: CGFloat(5 + i * 3))
                    }
                }
                .frame(height: 18)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(bpm)")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(bpm)))
                    Text("BPM")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("60 → 120")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(stableColor)
                    Text("every 4 bars")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .animation(.easeOut(duration: 0.18), value: bpm)
        }
    }
}
