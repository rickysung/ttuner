import SwiftUI

struct MetronomeSheet: View {
    @Bindable var state: AppState

    private let timeSignatures: [TimeSignature] = [.twoFour, .threeFour, .fourFour, .sixEight]

    enum ModeTab: String, CaseIterable { case simple = "Simple", poly = "Polyrhythm", gradual = "Gradual" }
    @State private var modeTab: ModeTab = .simple
    @State private var secondaryBeats: Int = 3
    @State private var gradualStart: Double = 90
    @State private var gradualEnd: Double = 120
    @State private var gradualBars: Int = 8

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

                Section("모드") {
                    Picker("Mode", selection: $modeTab) {
                        ForEach(ModeTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modeTab) { _, new in applyMode(tab: new) }

                    switch modeTab {
                    case .simple:
                        Text("기본 단일 트랙 메트로놈.").font(.footnote).foregroundStyle(.secondary)
                    case .poly:
                        Stepper("Secondary beats per bar: \(secondaryBeats)",
                                value: $secondaryBeats, in: 2...12)
                            .onChange(of: secondaryBeats) { _, _ in applyMode(tab: .poly) }
                        Text("Primary는 흰색, Secondary는 시안색으로 표시됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .gradual:
                        HStack {
                            Text("Start").frame(width: 60, alignment: .leading)
                            Slider(value: $gradualStart, in: 40...240, step: 1)
                            Text("\(Int(gradualStart))").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("End").frame(width: 60, alignment: .leading)
                            Slider(value: $gradualEnd, in: 40...240, step: 1)
                            Text("\(Int(gradualEnd))").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                        Stepper("Bars: \(gradualBars)", value: $gradualBars, in: 1...64)
                        Button("적용") { applyMode(tab: .gradual) }
                    }
                }

                Section("Subdivision / Count-in") {
                    Picker("Subdivision", selection: $state.metronome.subdivision) {
                        Text("Off").tag(1)
                        Text("2분할").tag(2)
                        Text("3분할").tag(3)
                        Text("4분할").tag(4)
                    }
                    Toggle("Subdivision 소리도 같이", isOn: $state.metronome.subdivisionAudible)
                    Stepper("Count-in: \(state.metronome.countInBars) bar",
                            value: $state.metronome.countInBars, in: 0...4)
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
            .onAppear { hydrateLocalsFromMode() }
        }
    }

    private func hydrateLocalsFromMode() {
        switch state.metronome.mode {
        case .simple: modeTab = .simple
        case .polyrhythm(let n):
            modeTab = .poly
            secondaryBeats = n
        case .gradual(let s, let e, let b):
            modeTab = .gradual
            gradualStart = s
            gradualEnd = e
            gradualBars = b
        }
    }

    private func applyMode(tab: ModeTab) {
        switch tab {
        case .simple: state.metronome.mode = .simple
        case .poly:   state.metronome.mode = .polyrhythm(secondaryBeats: max(2, secondaryBeats))
        case .gradual:
            state.metronome.mode = .gradual(
                startBPM: gradualStart,
                endBPM: gradualEnd,
                bars: max(1, gradualBars)
            )
            state.metronome.bpm = gradualStart
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
