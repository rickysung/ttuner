import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("오디오") {
                    Picker("샘플레이트", selection: $state.settings.sampleRatePreference) {
                        Text("자동").tag(0.0)
                        Text("48 kHz").tag(48_000.0)
                        Text("44.1 kHz").tag(44_100.0)
                    }
                    Picker("세션 모드", selection: $state.settings.sessionMode) {
                        ForEach(SessionAudioMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section("디스플레이") {
                    Picker("컬러맵", selection: $state.settings.colormap) {
                        ForEach(ColormapKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text("dB 하한")
                        Slider(value: $state.settings.dbFloor, in: -90...0)
                        Text("\(Int(state.settings.dbFloor))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("dB 상한")
                        Slider(value: $state.settings.dbCeil, in: 0...80)
                        Text("\(Int(state.settings.dbCeil))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("스무딩")
                        Slider(value: $state.settings.spectroBlur, in: 0...1)
                        Text(String(format: "%.0f%%", state.settings.spectroBlur * 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("볼륨 바 투명도")
                        Slider(value: $state.settings.volumeBarOpacity, in: 0...1)
                        Text(String(format: "%.0f%%", state.settings.volumeBarOpacity * 100))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }

                Section("튜너") {
                    Stepper("Reference A: \(Int(state.settings.referenceA)) Hz",
                            value: $state.settings.referenceA, in: 415...460, step: 1)
                    Stepper("Transpose: \(state.settings.transpose)",
                            value: $state.settings.transpose, in: -12...12)
                    Picker("표기법", selection: $state.settings.noteDisplay) {
                        Text("Sharp").tag(NoteDisplay.sharp)
                        Text("Flat").tag(NoteDisplay.flat)
                    }
                    HStack {
                        Text("안정성 임계 cents")
                        Slider(value: $state.settings.stabilityCents, in: 1...20, step: 1)
                        Text("\(Int(state.settings.stabilityCents))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }

                Section("타임라인") {
                    Picker("버퍼 길이", selection: $state.settings.timelineSeconds) {
                        Text("1분").tag(60)
                        Text("3분").tag(180)
                        Text("5분").tag(300)
                        Text("10분").tag(600)
                    }
                }

                Section("편의 기능") {
                    Toggle("Auto-tune-in", isOn: $state.settings.autoTuneIn)
                    Toggle("Silence-aware Pause", isOn: $state.settings.silenceAwarePause)
                    Toggle("Stable Note Detection", isOn: $state.settings.stableDetection)
                    Toggle("Cent History Trail", isOn: $state.settings.centTrail)
                    Toggle("Intonation Heatmap", isOn: $state.settings.intonationHeatmap)
                    Toggle("Loudness Glow", isOn: $state.settings.loudnessGlow)
                }

                Section("움직임 감지") {
                    Toggle("Movement-aware Pause", isOn: $state.settings.movementAwarePause)
                    Picker("민감도", selection: $state.settings.motionSensitivity) {
                        Text("민감").tag(MotionSensitivity.sensitive)
                        Text("보통").tag(MotionSensitivity.normal)
                        Text("둔감").tag(MotionSensitivity.dull)
                    }
                    Toggle("자동 재개", isOn: $state.settings.autoResume)
                }

                Section("디스플레이 & 햅틱") {
                    Toggle("Haptic on Beat", isOn: $state.settings.hapticOnBeat)
                    Toggle("화면 자동 잠금 방지", isOn: $state.settings.keepScreenOn)
                    Toggle("Discreet Mode 자동", isOn: $state.settings.discreetModeAuto)
                    Toggle("애니메이션 즉시 컷", isOn: $state.settings.reduceMotionOverride)
                }

                Section("프라이버시") {
                    Text("모든 오디오 데이터는 기기 RAM에서만 처리되며, 외부로 전송되지 않습니다. 네트워크 권한이 요청되지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("정보") {
                    Text("ttuner · v0.1 (Design Spec v1.0)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { state.showSettings = false }
                }
            }
        }
    }
}
