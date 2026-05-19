import SwiftUI

/// Layout drawn into the Picture-in-Picture floating window. Landscape
/// orientation so the card sits naturally along the edge of a sheet
/// music view without blocking notation. Left half is the readout
/// (note + Hz / drone status); right half is the visual feedback
/// (metronome dots + strobe + history or strings rail).
///
/// The view is rasterised to a pixel buffer by `TunerPIPController`
/// every CADisplayLink tick, so it must stay cheap and self-contained
/// — all state arrives via init arguments. Smoothness comes from
/// values the controller has already eased over time (e.g. `cents`)
/// rather than from SwiftUI implicit animations, which are a no-op
/// against frame-by-frame `ImageRenderer` snapshots.
struct TunerPIPView: View {
    let noteLabel: String?
    let cents: Double
    let frequency: Double
    let isStable: Bool
    /// Recent pitch readings, ordered oldest → newest. Each dot's `y`
    /// is computed from `renderTime - sample.time`, so the rail self-
    /// scrolls upward as time advances.
    let history: [PIPPitchSample]
    /// Time used to age the history dots — passed in so the layout is
    /// a pure function of the snapshot the controller captured.
    let renderTime: CFTimeInterval
    /// Latest metronome playback shape (nil when stopped). When
    /// present the bottom row lights the current beat dot from a
    /// TimelineView anchored at `barStartDate`.
    let metronome: MetronomeEngine.PlaybackState?
    /// Drone note label (e.g. "A4"), nil when no drone is playing.
    /// When present the Hz line is replaced with a "♪ A4 drone" pill
    /// so the user sees their reference at a glance.
    let droneLabel: String?
    /// Per-string labels for the active tuning preset (empty for
    /// chromatic). When non-empty the pitch-history rail is swapped
    /// for a compact strings row that highlights the current target.
    let presetLabels: [String]
    let presetActiveIndex: Int?
    let presetTunedIndices: Set<Int>

    /// Native render resolution. 5:2 landscape — short enough to ride
    /// along the edge of a score, wide enough that the readout +
    /// scale + history all coexist. Aspect ratio shapes the PIP
    /// window; pixel buffer scale multiplies for crisp Retina output.
    static let renderSize = CGSize(width: 200, height: 80)

    var body: some View {
        ZStack {
            background

            HStack(spacing: 8) {
                readout
                    .frame(width: 78, alignment: .leading)
                    .padding(.leading, 8)

                VStack(spacing: 3) {
                    metronomeRow
                        .frame(height: 14)
                    strobeBar
                        .frame(height: 11)
                    bottomRail
                }
                .padding(.trailing, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: Self.renderSize.width, height: Self.renderSize.height)
    }

    // MARK: - Readout (note + Hz / drone)

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(noteLabel ?? "—")
                .font(.system(size: 38, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(noteForeground)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .shadow(color: noteGlow, radius: 6)
                .shadow(color: noteGlow.opacity(0.5), radius: 11)

            // Drone gets priority over Hz — when active it tells the
            // user what reference they're playing against, which is
            // more useful than a redundant Hz repeat of the noteLabel.
            if let drone = droneLabel {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8, weight: .heavy))
                    Text("\(drone) drone")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .tracking(0.1)
                }
                .foregroundStyle(stableColor)
                .padding(.top, -1)
                .shadow(color: stableColor.opacity(0.55), radius: 4)
            } else {
                Text(hzText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .tracking(0.2)
                    .foregroundStyle(Color.white.opacity(hasReading ? 0.65 : 0.30))
                    .padding(.top, -1)
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.055, green: 0.060, blue: 0.075),
                Color(red: 0.005, green: 0.005, blue: 0.010)
            ], startPoint: .top, endPoint: .bottom)

            // Highlight on the left where the readout lives.
            RadialGradient(
                colors: [
                    Color.white.opacity(hasReading ? 0.07 : 0.025),
                    Color.clear
                ],
                center: UnitPoint(x: 0.22, y: 0.5),
                startRadius: 0,
                endRadius: 60
            )
        }
    }

    // MARK: - Strobe (ticks only, no colour zones)

    private var strobeBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let clamped = max(-50, min(50, cents))
            let needleX = (CGFloat(clamped) + 50) / 100 * w

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: w, height: 0.6)
                    .offset(y: h - 0.3)

                ForEach(Array(stride(from: -50, through: 50, by: 2)), id: \.self) { c in
                    let x = CGFloat(c + 50) / 100 * w
                    let isMajor = (c % 10 == 0)
                    let isCenter = (c == 0)
                    let tickH: CGFloat = isCenter ? h : (isMajor ? h * 0.55 : h * 0.28)
                    let tickW: CGFloat = isCenter ? 1.2 : (isMajor ? 0.8 : 0.5)
                    Rectangle()
                        .fill(Color.white.opacity(isCenter ? 0.85
                                                    : isMajor ? 0.50 : 0.20))
                        .frame(width: tickW, height: tickH)
                        .offset(x: x - tickW / 2, y: h - tickH)
                }

                if hasReading {
                    Capsule(style: .continuous)
                        .fill(needleColor)
                        .frame(width: 2.2, height: h + 4)
                        .shadow(color: needleColor.opacity(0.7), radius: 2.5)
                        .offset(x: needleX - 1.1, y: -2)
                }
            }
        }
    }

    // MARK: - Bottom rail (strings or pitch history)

    /// When a preset is active the rail becomes a compact strings row
    /// (more useful for tuning context). Chromatic mode keeps the
    /// scrolling pitch-history rail.
    @ViewBuilder
    private var bottomRail: some View {
        if presetLabels.isEmpty {
            pitchHistoryRail
        } else {
            stringsRail
        }
    }

    private var pitchHistoryRail: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5, height: h)
                .offset(x: w * 0.5 - 0.25)

            ForEach(Array(history.enumerated()), id: \.offset) { _, sample in
                let age = renderTime - sample.time
                let normAge = max(0, min(1, age / TunerPIPController.historyMaxAge))
                let clamped = max(-50, min(50, sample.cents))
                let x = (CGFloat(clamped) + 50) / 100 * w
                let y = h - CGFloat(normAge) * h
                let opacity = (1.0 - normAge) * 0.85
                Circle()
                    .fill(Color.white.opacity(opacity))
                    .frame(width: 2.4, height: 2.4)
                    .position(x: x, y: y)
            }
        }
    }

    private var stringsRail: some View {
        // Mini E A D G B E row. Active string lights blue; locked-in
        // strings stay blue too so the user can glance at PIP and see
        // "I have 3 of 6 in tune."
        HStack(spacing: 3) {
            ForEach(Array(presetLabels.enumerated()), id: \.offset) { idx, label in
                let isActive = presetActiveIndex == idx
                let isTuned = presetTunedIndices.contains(idx)
                Text(label)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(stringTextColor(active: isActive, tuned: isTuned))
                    .frame(minWidth: 11)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isActive ? stableColor.opacity(0.20) : Color.clear)
                    )
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(stringUnderlineColor(active: isActive, tuned: isTuned))
                            .frame(height: 1)
                            .padding(.horizontal, 1)
                            .offset(y: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func stringTextColor(active: Bool, tuned: Bool) -> Color {
        if active { return stableColor }
        if tuned { return Color.white.opacity(0.80) }
        return Color.white.opacity(0.45)
    }

    private func stringUnderlineColor(active: Bool, tuned: Bool) -> Color {
        if tuned { return stableColor }
        if active { return Color.white.opacity(0.50) }
        return Color.clear
    }

    // MARK: - Metronome row

    @ViewBuilder
    private var metronomeRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(metronome != nil ? stableColor : Color.white.opacity(0.25))
                .frame(width: 3.5, height: 3.5)
            Text(metronome != nil ? "\(Int(metronome!.bpm.rounded()))" : "—")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(metronome != nil ? .white : Color.white.opacity(0.40))

            Spacer(minLength: 4)

            if let m = metronome, m.bpm > 0, m.beatsPerBar > 0 {
                let secsPerBeat = 60.0 / m.bpm
                TimelineView(.periodic(from: m.barStartDate, by: secsPerBeat)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(m.barStartDate)
                    let beat = max(0, Int(elapsed / secsPerBeat)) % max(1, m.beatsPerBar)
                    metronomeDots(state: m, currentBeat: beat)
                        .transaction { $0.animation = nil }
                }
            }
        }
    }

    private func metronomeDots(state: MetronomeEngine.PlaybackState,
                                currentBeat: Int) -> some View {
        HStack(spacing: 2.2) {
            ForEach(0..<state.beatsPerBar, id: \.self) { i in
                let isCurrent = i == currentBeat
                let isAccent = state.accents.indices.contains(i) && state.accents[i]
                Circle()
                    .fill(dotFill(isCurrent: isCurrent, isAccent: isAccent))
                    .frame(width: isCurrent ? 4.5 : 3.2,
                           height: isCurrent ? 4.5 : 3.2)
            }
        }
    }

    private func dotFill(isCurrent: Bool, isAccent: Bool) -> Color {
        if isCurrent { return .white }
        if isAccent { return stableColor.opacity(0.85) }
        return Color.white.opacity(0.30)
    }

    // MARK: - Derived values

    private var hasReading: Bool { noteLabel != nil }

    private var hzText: String {
        guard hasReading, frequency > 0 else { return "— Hz" }
        return frequency >= 1000
            ? String(format: "%.0f Hz", frequency)
            : String(format: "%.1f Hz", frequency)
    }

    private var noteForeground: Color {
        guard hasReading else { return Color.white.opacity(0.30) }
        return isStable ? stableColor : .white
    }

    private var noteGlow: Color {
        guard hasReading, isStable else { return .clear }
        return stableColor.opacity(0.55)
    }

    private var stableColor: Color { Color.stable }

    private var needleColor: Color {
        isStable ? stableColor : .white
    }
}
