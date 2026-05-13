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

    var visibleSeconds: Float = 8 { didSet { renderer?.visibleSeconds = visibleSeconds } }
    var displayMinHz: Float = 50 { didSet { renderer?.displayMinHz = displayMinHz } }
    var displayMaxHz: Float = 4_000 { didSet { renderer?.displayMaxHz = displayMaxHz } }
    var orientation: AppOrientation = .portrait { didSet { renderer?.orientation = orientation } }
    var scrubMode: ScrubMode = .live { didSet { renderer?.scrubMode = scrubMode } }
    var colormap: ColormapKind = .monoBlue { didSet { renderer?.setColormap(colormap) } }
    var dbFloor: Float = -90 { didSet { renderer?.dbFloor = dbFloor } }
    var dbCeil: Float = 0 { didSet { renderer?.dbCeil = dbCeil } }
    var contentMinHz: Float = 50 { didSet { renderer?.contentMinHz = contentMinHz } }
    var contentMaxHz: Float = 20_000 { didSet { renderer?.contentMaxHz = contentMaxHz } }
    var heatmapEnabled: Bool = false { didSet { renderer?.heatmapEnabled = heatmapEnabled } }

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
        renderer?.setColormap(colormap)
    }

    func append(column: [Float]) {
        renderer?.append(column: column)
    }

    func updateBeats(_ markers: [BeatMarker]) {
        renderer?.updateBeats(markers, visibleSecondsCap: visibleSeconds)
    }

    func updatePitchTrail(_ trail: [PitchEvent], referenceA: Double, transpose: Int) {
        renderer?.updatePitchTrail(trail, referenceA: referenceA, transpose: transpose)
    }

    func updateHeatmap(_ samples: [(ageSeconds: Double, magnitude: Float)]) {
        renderer?.updateHeatmap(samples: samples)
    }
}
