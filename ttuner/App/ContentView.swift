import SwiftUI
import MetalKit

struct ContentView: View {
    let state: AppState
    @StateObject private var bridge: SpectrogramBridge
    @State private var scrubBaseSeconds: Double? = nil
    @State private var scrubBaseCameraOffset: Float? = nil
    @State private var pinchBaseSemitones: Float? = nil
    @State private var bottomPanel: BottomPanel = .none

    enum BottomPanel { case none, metronome, drone, settings }

    init(state: AppState) {
        self.state = state
        _bridge = StateObject(wrappedValue: SpectrogramBridge(displayBins: AnalysisEngine.cqtBinCount))
    }

    var body: some View {
        @Bindable var binding = state
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Picture-in-Picture source layer. Lives in the
                // window's view hierarchy so iOS will auto-start PIP
                // when the user backgrounds the app, but is sized
                // small and rendered at α≈0.02 so it isn't visible.
                PIPAttachmentView()
                    .frame(width: 80, height: 50)
                    .position(x: 40, y: 25)
                    .allowsHitTesting(false)

                MetalSpectrogramView(bridge: bridge)
                    .ignoresSafeArea()
                    .gesture(scrubGesture(in: geo.size))
                    .gesture(pinchGesture)
                    .gesture(exportGesture)
                    .onTapGesture(count: 2) { state.resetZoom() }
                    .opacity(1 - Double(state.discreetDim) * 0.6)

                LoudnessGlowOverlay(level: state.loudnessGlowLevel,
                                     sign: state.loudnessGlowSign)
                    .animation(.easeInOut(duration: 0.25), value: state.loudnessGlowLevel)

                PitchGridLabelsOverlay(bridge: bridge,
                                       transpose: state.settings.transpose,
                                       noteDisplay: state.settings.noteDisplay)
                    .allowsHitTesting(false)
                    .opacity(1 - Double(state.discreetDim))

                // Top: compact tuner card. Centered horizontally so it sits
                // squarely above the flame column.
                VStack(spacing: 6) {
                    TunerCard(state: state)
                        .padding(.top, 14)
                    if !state.selectedTuningPreset.isChromatic {
                        TuningStringRow(state: state)
                    }
                    MetronomeStatusChip(state: state) {
                        bottomPanel = bottomPanel == .metronome ? .none : .metronome
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .opacity(1 - Double(state.discreetDim))

                // Bottom: slide-up panel + stacked icon stack.
                VStack {
                    Spacer()
                    bottomLayer
                        .padding(.bottom, 18)
                }
                .opacity(1 - Double(state.discreetDim))

                if state.metronome.inCountIn {
                    Text("Count-in")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 60)
                        .transition(.opacity)
                }

                // Scrub indicator — visible whenever the user is inspecting
                // history. Shows how far back the timeline is offset and
                // offers a one-tap return to live, since dragging back to
                // exactly zero by hand is fiddly.
                if !state.scrubMode.isLive {
                    scrubBadge
                        .padding(.top, 196)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
                applyBpmScroll(bpm: state.metronome.bpm)
            }
            .onChange(of: geo.size) { _, newSize in
                state.updateOrientation(AppOrientation.from(newSize))
            }
            .onChange(of: state.metronome.bpm) { _, newBpm in
                applyBpmScroll(bpm: newBpm)
            }
            .onReceive(NotificationCenter.default.publisher(for: .didTickMetronome)) { _ in
                bridge.updateBeats(state.metronome.markers)
            }
            .sheet(isPresented: $binding.showShareSheet) {
                ShareSheet(items: state.pendingShareItems)
            }
            .sheet(isPresented: $binding.showPaywall) {
                PaywallSheet(pro: state.pro) {
                    state.showPaywall = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            // Re-enforce Pro gates when entitlement flips (e.g. a
            // refund downgrades the user mid-session).
            .onChange(of: state.pro.isPro) { _, _ in
                state.enforceProGates()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    /// Bottom layer: the active glass panel (if any) plus a vertical stack of
    /// circular icon buttons at the trailing edge. The icons are always on
    /// screen so the user can swap or dismiss panels with one tap.
    private var bottomLayer: some View {
        VStack(spacing: 8) {
            switch bottomPanel {
            case .metronome:
                MetronomePanel(state: state, onClose: { closePanel() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .drone:
                DronePanel(state: state, onClose: { closePanel() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .settings:
                SettingsPanel(state: state, onClose: { closePanel() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .none:
                EmptyView()
            }

            HStack {
                Spacer()
                VStack(spacing: 10) {
                    iconButton(system: "pip.enter",
                               active: false) {
                        TunerPIPController.shared.startManually()
                    }
                    iconButton(system: "metronome",
                               active: bottomPanel == .metronome) {
                        toggle(.metronome)
                    }
                    iconButton(system: state.drone.isPlaying ? "waveform.circle.fill" : "waveform",
                               active: bottomPanel == .drone) {
                        // Panel is free — anyone can tap notes to hear
                        // a one-shot reference tone. The drone-mode
                        // toggle inside is what's Pro-gated.
                        toggle(.drone)
                    }
                    iconButton(system: "gearshape.fill",
                               active: bottomPanel == .settings) {
                        toggle(.settings)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: bottomPanel)
    }

    private func iconButton(system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? .white : Color.white.opacity(0.75))
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(active ? 0.95 : 0.55)
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(active ? 0.45 : 0.18), lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
    }

    /// Scale the visible-window so the timeline scroll speed matches the
    /// metronome. 120 BPM is the anchor (8s window — original feel); 240
    /// BPM compresses to 4s (everything moves twice as fast), 60 BPM
    /// stretches to 16s. Bridge clamps still apply at the renderer.
    private func applyBpmScroll(bpm: Double) {
        let base: Float = 8.0
        let scaled = base * Float(120.0 / max(20.0, bpm))
        bridge.visibleSeconds = max(2.0, min(24.0, scaled))
    }

    private func toggle(_ panel: BottomPanel) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            bottomPanel = (bottomPanel == panel) ? .none : panel
        }
    }

    private func closePanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            bottomPanel = .none
        }
    }

    /// "Inspecting history" pill. Tapping it (or dragging the canvas
    /// back to offset 0) returns to live capture. We deliberately keep
    /// this as the dedicated affordance instead of hijacking the canvas
    /// tap, because the canvas also takes double-tap (reset zoom) and
    /// long-press (export) gestures and the resolution between them
    /// would feel fiddly.
    private var scrubBadge: some View {
        Button {
            // Reset both axes — exits scrub mode cleanly.
            state.setScrubCameraOffset(0)
            state.setScrubSeconds(0)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(String(format: "−%.1fs", state.currentScrubSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("· tap to resume")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.7))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                Text("Microphone access needed").font(.headline)
                Text("ttuner analyses microphone input to detect pitch. Grant access in Settings to start tuning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func scrubGesture(in size: CGSize) -> some Gesture {
        // Two-axis scrub: vertical axis (in portrait) controls how far
        // back in time we're inspecting, horizontal axis pans the camera
        // across neighbouring pitches. Either axis can drive the user
        // into scrub mode on its own, so a pure left-right swipe works
        // for "I just want to look at adjacent notes."
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let isLandscape = AppOrientation.from(size).isLandscape
                let timeAxisPoints = isLandscape
                    ? value.translation.width
                    : value.translation.height
                let pitchAxisPoints = isLandscape
                    ? value.translation.height
                    : value.translation.width
                let timeScreen = max(1, isLandscape ? size.width : size.height)
                let pitchScreen = max(1, isLandscape ? size.height : size.width)

                if scrubBaseSeconds == nil {
                    scrubBaseSeconds = state.currentScrubSeconds
                    scrubBaseCameraOffset = state.scrubCameraOffsetSemitones
                }
                let baseTime = scrubBaseSeconds ?? 0
                let baseOff = scrubBaseCameraOffset ?? 0

                let secondsPerPoint = Double(bridge.visibleSeconds) / Double(timeScreen)
                let semitonesPerPoint = Double(state.visibleSemitones) / Double(pitchScreen)

                // Apply camera offset FIRST so a pure horizontal drag
                // (timeAxisPoints near 0) still has a non-zero camera
                // offset when setScrubSeconds(0) checks the condition.
                let nextOffset = baseOff - Float(Double(pitchAxisPoints) * semitonesPerPoint)
                state.setScrubCameraOffset(nextOffset)

                let nextSeconds = baseTime + Double(timeAxisPoints) * secondsPerPoint
                state.setScrubSeconds(nextSeconds)
            }
            .onEnded { _ in
                scrubBaseSeconds = nil
                scrubBaseCameraOffset = nil
            }
    }

    private var pinchGesture: some Gesture {
        // Pinch controls the visible pitch-grid width in semitones.
        // Default (and minimum) is 6 — a half octave, the tightest
        // view. Spreading fingers widens the view up to two octaves
        // (24). The mapping is `new = base * scale`: spreading fingers
        // (scale > 1) reveals more semitones, pinching them together
        // (scale < 1) narrows back toward the default.
        MagnificationGesture()
            .onChanged { scale in
                if pinchBaseSemitones == nil {
                    pinchBaseSemitones = state.visibleSemitones
                }
                let base = pinchBaseSemitones ?? AppState.visibleSemitonesMin
                state.setVisibleSemitones(base * Float(scale))
            }
            .onEnded { _ in pinchBaseSemitones = nil }
    }

    private var exportGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.8)
            .onEnded { _ in
                guard !state.scrubMode.isLive else { return }
                state.exportVisibleClip()
            }
    }
}

extension Notification.Name {
    static let didTickMetronome = Notification.Name("ttuner.didTickMetronome")
}
