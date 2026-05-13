import SwiftUI
import MetalKit

struct ContentView: View {
    let state: AppState
    @StateObject private var bridge: SpectrogramBridge

    init(state: AppState) {
        self.state = state
        _bridge = StateObject(wrappedValue: SpectrogramBridge(displayBins: state.settings.displayBins))
    }

    var body: some View {
        @Bindable var binding = state
        GeometryReader { geo in
            ZStack(alignment: layoutAlignment(in: geo.size)) {
                MetalSpectrogramView(bridge: bridge)
                    .ignoresSafeArea()
                    .gesture(scrubGesture)
                    .gesture(pinchGesture)
                    .onTapGesture(count: 2) { state.resetZoom() }

                if AppOrientation.from(geo.size).isLandscape {
                    HStack {
                        TunerCard(state: state)
                            .frame(maxWidth: 260)
                            .padding(.leading, 12)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            settingsButton
                            MetronomeCard(state: state, onShowSheet: { state.showMetronomeSheet = true })
                                .frame(maxWidth: 260)
                        }
                        .padding(.trailing, 12)
                    }
                    .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            TunerCard(state: state)
                            Spacer()
                            settingsButton
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        Spacer()
                        MetronomeCard(state: state, onShowSheet: { state.showMetronomeSheet = true })
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                }

                if state.pausedToastVisible {
                    Text("🔒 PAUSED")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }

                if let bpm = state.autoTuneInSuggestion {
                    HStack(spacing: 12) {
                        Text("이 템포가 맞나요? \(Int(bpm)) BPM")
                        Button("적용") { state.acceptAutoTuneInSuggestion() }.buttonStyle(.borderedProminent)
                        Button("닫기") { state.dismissAutoTuneInSuggestion() }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if state.permissionDenied {
                    permissionCard
                        .padding(40)
                }
            }
            .onAppear {
                state.bootstrap(bridge: bridge)
                state.updateOrientation(AppOrientation.from(geo.size))
                state.metronome.onScheduleMarker = { _ in
                    NotificationCenter.default.post(name: .didTickMetronome, object: nil)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                state.updateOrientation(AppOrientation.from(newSize))
            }
            .onReceive(NotificationCenter.default.publisher(for: .didTickMetronome)) { _ in
                bridge.updateBeats(state.metronome.markers)
            }
            .sheet(isPresented: $binding.showMetronomeSheet) { MetronomeSheet(state: state) }
            .sheet(isPresented: $binding.showSettings) { SettingsView(state: state) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    private var settingsButton: some View {
        Button { state.showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                Text("마이크 권한이 필요합니다").font(.headline)
                Text("튜너와 스펙트로그램이 마이크 입력을 분석하려면 권한이 필요합니다. 설정 앱에서 권한을 허용해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("설정 앱 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func layoutAlignment(in size: CGSize) -> Alignment {
        AppOrientation.from(size).isLandscape ? .center : .top
    }

    private var scrubGesture: some Gesture {
        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                if state.scrubMode.isLive {
                    state.toggleScrub()
                }
                let isLandscape = AppOrientation.from(UIScreen.main.bounds.size).isLandscape
                let dx = isLandscape ? value.translation.width : value.translation.height
                let visible = Double(bridge.visibleSeconds)
                let delta = Double(-dx / 50) * visible * 0.02
                state.nudgeScrub(deltaSeconds: delta)
            }
        let tap = TapGesture(count: 1).onEnded { _ in state.toggleScrub() }
        return drag.exclusively(before: tap)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let logMin = log(Double(state.zoomMinHz))
                let logMax = log(Double(state.zoomMaxHz))
                let center = (logMin + logMax) * 0.5
                let half = (logMax - logMin) * 0.5 / scale
                let newMin = Float(exp(max(log(20.0), center - half)))
                let newMax = Float(exp(min(log(20_000.0), center + half)))
                state.setZoom(minHz: newMin, maxHz: newMax)
            }
    }
}

extension Notification.Name {
    static let didTickMetronome = Notification.Name("ttuner.didTickMetronome")
}
