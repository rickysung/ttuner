import SwiftUI
import MetalKit

struct MetalSpectrogramView: UIViewRepresentable {
    @ObservedObject var bridge: SpectrogramBridge

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120
        view.layer.isOpaque = true
        view.backgroundColor = .black

        if let renderer = SpectrogramRenderer(view: view,
                                              displayBins: bridge.displayBins,
                                              textureColumns: 1024) {
            bridge.attach(renderer: renderer)
        }
        bridge.metalView = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        bridge.applyVisualSettings()
    }
}

final class SpectrogramBridge: ObservableObject {
    let displayBins: Int
    private(set) var renderer: SpectrogramRenderer?
    weak var metalView: MTKView?

    /// Camera state mirrored from the renderer for SwiftUI overlays
    /// (e.g. the pitch-line note labels). Read each frame via TimelineView.
    var currentCameraSemitone: Float { renderer?.publishedCameraSemitone ?? 60 }
    var currentSemitoneSpacing: Float { renderer?.publishedSemitoneSpacing ?? 2.0 / 6.0 }

    var visibleSeconds: Float = 8 { didSet { renderer?.visibleSeconds = visibleSeconds } }
    var displayMinHz: Float = 30 { didSet { renderer?.displayMinHz = displayMinHz } }
    var displayMaxHz: Float = 6_000 { didSet { renderer?.displayMaxHz = displayMaxHz } }
    var orientation: AppOrientation = .portrait { didSet { renderer?.orientation = orientation } }
    var scrubMode: ScrubMode = .live { didSet { renderer?.scrubMode = scrubMode } }
    var colormap: ColormapKind = .magma { didSet { renderer?.setColormap(colormap) } }
    var dbFloor: Float = -45 { didSet { renderer?.dbFloor = dbFloor } }
    var dbCeil: Float = 35 { didSet { renderer?.dbCeil = dbCeil } }
    var contentMinHz: Float = 30 { didSet { renderer?.contentMinHz = contentMinHz } }
    var contentMaxHz: Float = 20_000 { didSet { renderer?.contentMaxHz = contentMaxHz } }
    var heatmapEnabled: Bool = false { didSet { renderer?.heatmapEnabled = heatmapEnabled } }
    /// Audio frames (hops) per second — defines how many seconds the spectrogram
    /// ring buffer covers, which the beat markers/heatmap then use to align.
    var framesPerSecond: Float = 93.75 { didSet { renderer?.framesPerSecond = framesPerSecond } }
    var volumeBarOpacity: Float = 0.70 { didSet { renderer?.rmsBarOpacity = volumeBarOpacity } }
    var spectroBlur: Float = 1.0 { didSet { renderer?.spectroBlur = spectroBlur } }
    /// Pitch-grid width in semitones. 6 = half octave (default/min),
    /// 24 = two octaves (max zoom-out via pinch).
    var visibleSemitones: Float = 6 { didSet { renderer?.visibleSemitones = visibleSemitones } }
    /// Horizontal camera offset while scrubbing (semitones). 0 keeps the
    /// camera at the scrub-entry pitch.
    var scrubCameraOffsetSemitones: Float = 0 {
        didSet { renderer?.scrubCameraOffsetSemitones = scrubCameraOffsetSemitones }
    }

    init(displayBins: Int) {
        self.displayBins = displayBins
    }

    func attach(renderer: SpectrogramRenderer) {
        self.renderer = renderer
        applyVisualSettings()
    }

    func applyVisualSettings() {
        renderer?.visibleSeconds = visibleSeconds
        renderer?.displayMinHz = displayMinHz
        renderer?.displayMaxHz = displayMaxHz
        renderer?.orientation = orientation
        renderer?.scrubMode = scrubMode
        renderer?.dbFloor = dbFloor
        renderer?.dbCeil = dbCeil
        renderer?.contentMinHz = contentMinHz
        renderer?.contentMaxHz = contentMaxHz
        renderer?.heatmapEnabled = heatmapEnabled
        renderer?.framesPerSecond = framesPerSecond
        renderer?.rmsBarOpacity = volumeBarOpacity
        renderer?.spectroBlur = spectroBlur
        renderer?.visibleSemitones = visibleSemitones
        renderer?.scrubCameraOffsetSemitones = scrubCameraOffsetSemitones
        renderer?.setColormap(colormap)
    }

    func append(column: [Float], rmsDb: Float) {
        renderer?.append(column: column, rmsDb: rmsDb)
    }

    func updateBeats(_ markers: [BeatMarker]) {
        renderer?.updateBeats(markers, visibleSecondsCap: visibleSeconds)
    }

    func updatePitchTrail(_ trail: [PitchEvent], referenceA: Double, transpose: Int) {
        renderer?.updatePitchTrail(trail, referenceA: referenceA, transpose: transpose)
    }

    /// Append a pitch sample for the vertical timeline / dot trail.
    func appendPitch(hostTime: UInt64, semitone: Float, clarity: Float, rmsDb: Float) {
        renderer?.appendPitchPoint(hostTime: hostTime, semitone: semitone, clarity: clarity, rmsDb: rmsDb)
    }

    /// Update the live pitch reading driving the particle force field.
    func updateLivePitch(semitone: Float?, clarity: Float, rmsDb: Float) {
        renderer?.updateCurrentPitch(semitone: semitone, clarity: clarity, rmsDb: rmsDb)
    }

    func updateHeatmap(_ samples: [(ageSeconds: Double, magnitude: Float)]) {
        renderer?.updateHeatmap(samples: samples)
    }
}
