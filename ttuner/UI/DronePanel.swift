import SwiftUI

/// Bottom slide-up "Pitch" panel — a 12-note chromatic grid with an
/// octave stepper. Tapping a note plays it. The behavior of that
/// tap depends on the Drone Mode toggle:
///
///   • Drone Mode OFF (free + Pro): tap fires a 1.2s reference tone
///     that fades out. Same one-shot behavior `ReferenceTone` has
///     always provided to in-tune string rows.
///   • Drone Mode ON  (Pro only): tap starts a sustained drone
///     looped through `DroneEngine`. Tap the same note again or
///     anywhere else to stop / switch.
///
/// The panel itself is free — non-Pro users can hear reference tones
/// and discover the feature before being asked to pay. Only the
/// drone-mode toggle and its sustained-playback behavior are gated.
struct DronePanel: View {
    @Bindable var state: AppState
    var onClose: () -> Void

    @State private var octave: Int = 4

    private let chromaticLabels = ["C", "C#", "D", "D#", "E", "F",
                                    "F#", "G", "G#", "A", "A#", "B"]
    /// Flat-display equivalents of the sharp labels above. Kept aligned
    /// by index so a single sharp/flat toggle drives both rendering and
    /// the MIDI mapping.
    private let chromaticFlatLabels = ["C", "Db", "D", "Eb", "E", "F",
                                         "Gb", "G", "Ab", "A", "Bb", "B"]

    var body: some View {
        GlassCard(cornerRadius: 24, density: 0.40) {
            VStack(spacing: 14) {
                header
                Divider().background(Color.white.opacity(0.10))
                octaveRow
                Divider().background(Color.white.opacity(0.10))
                noteGrid
                Divider().background(Color.white.opacity(0.10))
                droneModeRow
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 14)
        .onAppear { snapOctaveToCurrent() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Pitch")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if let midi = state.drone.currentMidi {
                Text("· drone \(noteName(forMidi: midi))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(stableColor)
            }
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

    // MARK: Octave row

    private var octaveRow: some View {
        HStack(spacing: 10) {
            Text("Octave")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            stepperBtn(system: "minus", enabled: octave > 1) {
                octave = max(1, octave - 1)
                retriggerIfPlaying()
            }
            Text("\(octave)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 24)
            stepperBtn(system: "plus", enabled: octave < 7) {
                octave = min(7, octave + 1)
                retriggerIfPlaying()
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Note grid

    private var noteGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<12, id: \.self) { semitone in
                let midi = midiFor(semitone: semitone, octave: octave)
                let isDroning = isDroneActive && state.drone.currentMidi == midi
                Button {
                    tapNote(midi: midi)
                } label: {
                    noteButton(label: displayLabel(forSemitone: semitone),
                               isDroning: isDroning)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private func noteButton(label: String, isDroning: Bool) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .heavy, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(isDroning ? .white : Color.white.opacity(0.80))
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDroning ? stableColor.opacity(0.85)
                                     : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDroning ? stableColor : Color.white.opacity(0.12),
                            lineWidth: isDroning ? 1.0 : 0.6)
            )
            .shadow(color: isDroning ? stableColor.opacity(0.45) : .clear,
                    radius: 4)
    }

    // MARK: Drone-mode toggle

    /// Toggle row that promotes the panel from "tap to hear" into
    /// "tap to hold". Pro-gated: tapping while not Pro opens the
    /// paywall instead of flipping the switch.
    private var droneModeRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Drone Mode")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    if !state.pro.isPro {
                        proBadge
                    }
                }
                Text(isDroneActive
                     ? "Tap a note to hold its pitch continuously."
                     : "Tap plays a short reference tone.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 4)
            toggleSwitch
        }
        .padding(.horizontal, 4)
    }

    private var toggleSwitch: some View {
        Button {
            if !state.pro.isPro {
                state.showPaywall = true
                return
            }
            state.settings.droneModeEnabled.toggle()
            if !state.settings.droneModeEnabled, state.drone.isPlaying {
                state.stopDrone()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(isDroneActive ? stableColor.opacity(0.85)
                                         : Color.white.opacity(0.15))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .offset(x: isDroneActive ? 7 : -7)
                    .shadow(color: .black.opacity(0.30), radius: 1, y: 0.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.20, dampingFraction: 0.85),
                   value: isDroneActive)
    }

    private var proBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Pro")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(stableColor)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(stableColor.opacity(0.18), in: Capsule())
    }

    // MARK: Helpers

    /// Effective "drone mode is on": setting enabled AND user is Pro.
    /// The setting can linger as `true` if a Pro user downgraded
    /// between sessions before `enforceProGates` runs, but we treat
    /// it as off for behavior purposes.
    private var isDroneActive: Bool {
        state.settings.droneModeEnabled && state.pro.isPro
    }

    private func tapNote(midi: Int) {
        if isDroneActive {
            if state.drone.currentMidi == midi {
                state.stopDrone()
            } else {
                state.startDrone(midi: midi)
            }
        } else {
            // Free path — fire-and-forget reference tone. Same helper
            // used by the `TuningStringRow` pills, so the auditory
            // experience matches across the app.
            ReferenceTone.shared.play(midi: midi,
                                       referenceA: state.settings.referenceA)
        }
    }

    private func stepperBtn(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.25))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(enabled ? 0.12 : 0.04), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// When the octave changes while a drone is playing, restart it
    /// at the new octave so the user's intent ("octave up") is honored
    /// without making them re-tap the same letter.
    private func retriggerIfPlaying() {
        guard let current = state.drone.currentMidi else { return }
        let semitone = ((current % 12) + 12) % 12
        let next = midiFor(semitone: semitone, octave: octave)
        if next != current {
            state.startDrone(midi: next)
        }
    }

    /// Sync the octave selector to whatever's currently playing when
    /// the panel opens. Keeps the UI honest if the drone was started
    /// from a previous session.
    private func snapOctaveToCurrent() {
        guard let midi = state.drone.currentMidi else { return }
        octave = (midi / 12) - 1
    }

    private func midiFor(semitone: Int, octave: Int) -> Int {
        (octave + 1) * 12 + semitone
    }

    private func displayLabel(forSemitone semitone: Int) -> String {
        switch state.settings.noteDisplay {
        case .sharp: return chromaticLabels[semitone]
        case .flat:  return chromaticFlatLabels[semitone]
        }
    }

    private func noteName(forMidi midi: Int) -> String {
        NoteMapper.label(forMidi: midi, display: state.settings.noteDisplay)
    }

    private var stableColor: Color { Color.stable }
}
