import SwiftUI

struct MetronomeSheet: View {
    @Bindable var state: AppState

    private let timeSignatures: [TimeSignature] = [.twoFour, .threeFour, .fourFour, .sixEight]

    var body: some View {
        NavigationStack {
            Form {
                Section("BPM") {
                    HStack {
                        Slider(value: $state.metronome.bpm, in: 30...260, step: 1)
                        Text("\(Int(state.metronome.bpm.rounded()))").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    Button("Tap Tempo") { state.metronome.registerTap() }
                }

                Section("박자") {
                    HStack(spacing: 8) {
                        ForEach(timeSignatures, id: \.label) { sig in
                            Button(sig.label) {
                                state.metronome.timeSignature = sig
                                state.metronome.accentPattern = TimeSignature.defaultAccentPattern(for: sig)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(state.metronome.timeSignature == sig
                                        ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.18),
                                        in: Capsule())
                        }
                    }
                }

                Section("강세 패턴") {
                    HStack(spacing: 8) {
                        ForEach(0..<state.metronome.accentPattern.count, id: \.self) { i in
                            let a = state.metronome.accentPattern[i]
                            Button {
                                state.metronome.accentPattern[i] = a.next()
                            } label: {
                                Text(symbol(for: a))
                                    .font(.title3.bold())
                                    .frame(width: 44, height: 44)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("사운드") {
                    Picker("톤", selection: $state.metronome.tone) {
                        Text("Wood").tag("wood")
                        Text("Click").tag("click")
                        Text("Beep").tag("beep")
                        Text("Subtle").tag("subtle")
                    }
                    Toggle("박마다 햅틱", isOn: $state.settings.hapticOnBeat)
                    Toggle("BT 지연 보정", isOn: $state.settings.btLatencyCompensation)
                }
            }
            .navigationTitle("메트로놈")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { state.showMetronomeSheet = false }
                }
            }
        }
    }

    private func symbol(for a: Accent) -> String {
        switch a {
        case .off:    return "·"
        case .soft:   return "•"
        case .normal: return "●"
        case .accent: return "◆"
        }
    }
}
