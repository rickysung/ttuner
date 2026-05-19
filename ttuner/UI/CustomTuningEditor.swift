import SwiftUI

/// Modal editor for creating or revising a user-defined tuning. The
/// caller passes in the seed `CustomTuning` (or builds a fresh one
/// for new entries) plus `onSave` / `onCancel` handlers, and the
/// editor takes care of presenting the name field, the per-string
/// note steppers, and the add/remove-string buttons.
struct CustomTuningEditor: View {
    @Bindable var state: AppState
    @State private var name: String
    @State private var notes: [Int]
    private let originalId: UUID?

    var onSave: (CustomTuning) -> Void
    var onCancel: () -> Void

    init(state: AppState,
         seed: CustomTuning?,
         onSave: @escaping (CustomTuning) -> Void,
         onCancel: @escaping () -> Void) {
        self.state = state
        self._name = State(initialValue: seed?.name ?? "My Tuning")
        // Default to guitar-shape on new entries so the user has a
        // reasonable starting point rather than an empty grid.
        self._notes = State(initialValue: seed?.midiNotes ?? [40, 45, 50, 55, 59, 64])
        self.originalId = seed?.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.06, green: 0.07, blue: 0.10),
                Color(red: 0.01, green: 0.01, blue: 0.02)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        nameField
                        notesList
                        addStringButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.70))
                .buttonStyle(.plain)
            Spacer()
            Text(originalId == nil ? "New Tuning" : "Edit Tuning")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let final = CustomTuning(
                    id: originalId ?? UUID(),
                    name: trimmed.isEmpty ? "My Tuning" : trimmed,
                    midiNotes: notes
                )
                onSave(final)
            }
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .foregroundStyle(stableColor)
            .buttonStyle(.plain)
            .disabled(notes.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    // MARK: Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
            TextField("My Tuning", text: $name)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .tint(stableColor)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    // MARK: Notes list

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Strings")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("\(notes.count) string\(notes.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
            }

            VStack(spacing: 6) {
                ForEach(notes.indices, id: \.self) { idx in
                    noteRow(index: idx)
                }
            }
        }
    }

    private func noteRow(index: Int) -> some View {
        let midi = notes[index]
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
                .frame(width: 16, alignment: .leading)

            Text(NoteMapper.label(forMidi: midi, display: state.settings.noteDisplay))
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)

            Spacer()

            stepper(systemName: "minus") {
                guard notes[index] > 21 else { return }
                notes[index] -= 1
            }
            stepper(systemName: "plus") {
                guard notes[index] < 108 else { return }
                notes[index] += 1
            }

            Button {
                guard notes.count > 1 else { return }
                notes.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(notes.count <= 1)
            .opacity(notes.count > 1 ? 1 : 0.30)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var addStringButton: some View {
        Button {
            // Default new strings to the highest pitched note + a 4th
            // (5 semitones) so they fall in a musically plausible
            // range without the user having to scroll the stepper.
            let next = (notes.last ?? 64) + 5
            notes.append(min(108, next))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Add string")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(stableColor)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                stableColor.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(notes.count >= 12)
        .opacity(notes.count >= 12 ? 0.4 : 1.0)
    }

    private func stepper(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        Text("Pick any chromatic pitch per string. Drag the steppers up and down to set, or remove strings you don't need.")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.40))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
    }

    private var stableColor: Color { Color.stable }
}
