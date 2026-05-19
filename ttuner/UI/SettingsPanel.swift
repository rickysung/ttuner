import SwiftUI

/// Settings slide-up panel — glassmorphic, replaces the modal bottom
/// sheet. Same content the previous `SettingsView` exposed, just laid
/// out for the new bottom-panel chrome.
struct SettingsPanel: View {
    @Bindable var state: AppState
    var onClose: () -> Void

    /// Drives the modal editor sheet for create / edit flows on
    /// custom tunings. `nil` while the sheet is dismissed.
    @State private var customEditorSeed: CustomEditorMode? = nil

    enum CustomEditorMode: Identifiable {
        case new
        case edit(CustomTuning)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let t): return t.id.uuidString
            }
        }
        var seedTuning: CustomTuning? {
            switch self {
            case .new: return nil
            case .edit(let t): return t
            }
        }
    }

    var body: some View {
        GlassCard(cornerRadius: 24, density: 0.40) {
            VStack(spacing: 12) {
                header
                Divider().background(Color.white.opacity(0.10))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        tunerSection
                        audioSection
                        featureSection
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 14)
        .sheet(item: $customEditorSeed) { mode in
            CustomTuningEditor(
                state: state,
                seed: mode.seedTuning,
                onSave: { tuning in
                    saveCustomTuning(tuning)
                    customEditorSeed = nil
                },
                onCancel: { customEditorSeed = nil }
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
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

    // MARK: - Tuner

    private var tunerSection: some View {
        SectionBox(title: "Tuner") {
            HStack {
                Text("Instrument")
                Spacer()
                if state.pro.isPro {
                    Picker("Instrument", selection: $state.settings.tuningPresetId) {
                        ForEach(state.allTuningPresets, id: \.id) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else {
                    Button {
                        state.showPaywall = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("Chromatic")
                                .foregroundStyle(.secondary)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.stable)
                            Text("Pro")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.stable)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(
                                    Color.stable.opacity(0.18),
                                    in: Capsule()
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Reference A")
                Spacer()
                Stepper("\(Int(state.settings.referenceA)) Hz",
                        value: $state.settings.referenceA, in: 415...460, step: 1)
                    .labelsHidden()
                Text("\(Int(state.settings.referenceA)) Hz")
                    .monospacedDigit().font(.callout)
            }
            HStack {
                Text("Transpose")
                Spacer()
                Stepper("\(state.settings.transpose)",
                        value: $state.settings.transpose, in: -12...12)
                    .labelsHidden()
                Text("\(state.settings.transpose)")
                    .monospacedDigit().font(.callout)
            }
            Picker("Notation", selection: $state.settings.noteDisplay) {
                Text("Sharp").tag(NoteDisplay.sharp)
                Text("Flat").tag(NoteDisplay.flat)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Stability ±¢")
                Slider(value: $state.settings.stabilityCents, in: 1...20, step: 1)
                Text("\(Int(state.settings.stabilityCents))")
                    .monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            if state.pro.isPro {
                customTuningsRow
            }
        }
    }

    // MARK: Custom tunings affordance

    /// Edit / delete on the currently selected custom tuning, plus an
    /// always-on "+ New" button. Built-in selections collapse the edit
    /// row so it stays out of the way until relevant.
    @ViewBuilder
    private var customTuningsRow: some View {
        let selectedCustom = state.settings.customTunings.first {
            $0.presetId == state.settings.tuningPresetId
        }
        VStack(alignment: .leading, spacing: 6) {
            if let custom = selectedCustom {
                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(Color.stable)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Color.stable.opacity(0.18),
                            in: Capsule()
                        )
                    Spacer()
                    Button {
                        customEditorSeed = .edit(custom)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    Button {
                        deleteCustomTuning(id: custom.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color(red: 1.0, green: 0.50, blue: 0.50))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                customEditorSeed = .new
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("New custom tuning")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.stable)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Custom tunings — persistence

    private func saveCustomTuning(_ tuning: CustomTuning) {
        var list = state.settings.customTunings
        if let idx = list.firstIndex(where: { $0.id == tuning.id }) {
            list[idx] = tuning
        } else {
            list.append(tuning)
        }
        state.settings.customTunings = list
        // Auto-select the just-saved entry so the user sees the
        // string row update immediately.
        state.settings.tuningPresetId = tuning.presetId
    }

    private func deleteCustomTuning(id: UUID) {
        var list = state.settings.customTunings
        list.removeAll { $0.id == id }
        state.settings.customTunings = list
        // If we just deleted the currently active preset, snap back
        // to chromatic so the UI doesn't keep showing a ghost preset.
        if !state.allTuningPresets.contains(where: { $0.id == state.settings.tuningPresetId }) {
            state.settings.tuningPresetId = "chromatic"
        }
    }

    // MARK: - Display

    // MARK: - Audio

    private var audioSection: some View {
        SectionBox(title: "Audio") {
            Picker("Sample rate", selection: $state.settings.sampleRatePreference) {
                Text("Auto").tag(0.0)
                Text("48 kHz").tag(48_000.0)
                Text("44.1 kHz").tag(44_100.0)
            }
            .pickerStyle(.menu)
            Picker("Session", selection: $state.settings.sessionMode) {
                ForEach(SessionAudioMode.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Feature toggles

    private var featureSection: some View {
        SectionBox(title: "Behavior") {
            Toggle("Movement-aware pause", isOn: $state.settings.movementAwarePause)
            Toggle("Keep screen awake", isOn: $state.settings.keepScreenOn)
        }
    }
}

/// Minimal labeled container for a settings group — matches the glass
/// aesthetic without the iOS form chrome.
private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            VStack(spacing: 8) { content }
                .padding(10)
                .background(Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
