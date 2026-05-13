import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

private struct Uniforms {
    var writeHeadNorm: Float = 0
    var dbFloor: Float = -90
    var dbCeil: Float = 0
    var zoomMinLog: Float = 0
    var zoomMaxLog: Float = 0
    var fftMinLog: Float = 0
    var fftMaxLog: Float = 0
    var nowTime: Float = 0
    var visibleSeconds: Float = 8
    var isLandscape: Float = 0
    var scrubOffsetNorm: Float = 0
    var pitchTrailCount: Float = 0
    var showHeatmap: Float = 0
    var bandSizeNorm: Float = 0.05
}

private struct BeatVertexIn {
    var along: Float
    var across: Float
    var accent: Float
    var track: Float
}

private struct PitchVertexIn {
    var along: Float
    var across: Float
    var clarity: Float
}

private struct HeatmapVertexIn {
    var along: Float
    var across: Float
    var magnitude: Float
}

final class SpectrogramRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private weak var view: MTKView?

    private var spectroTexture: MTLTexture
    private var colormapTexture: MTLTexture
    private var pipeline: MTLRenderPipelineState
    private var beatPipeline: MTLRenderPipelineState
    private var pitchPipeline: MTLRenderPipelineState
    private var heatmapPipeline: MTLRenderPipelineState

    private let textureColumns: Int
    private let textureRows: Int
    private(set) var writeColumn: Int = 0

    private(set) var uniforms = Uniforms()
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    private var beatVertexBuffer: MTLBuffer?
    private var beatInstanceCount: Int = 0
    private var pitchVertexBuffer: MTLBuffer?
    private var pitchVertexCount: Int = 0
    private var heatmapVertexBuffer: MTLBuffer?
    private var heatmapVertexCount: Int = 0

    var visibleSeconds: Float = 8
    var displayMinHz: Float = 50
    var displayMaxHz: Float = 4_000
    var contentMinHz: Float = 50
    var contentMaxHz: Float = 20_000
    var dbFloor: Float = -90
    var dbCeil: Float = 0
    var orientation: AppOrientation = .portrait
    var scrubMode: ScrubMode = .live
    var heatmapEnabled: Bool = false

    init?(view: MTKView, displayBins: Int, textureColumns: Int = 1024) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        view.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.view = view

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: textureColumns,
            height: displayBins,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else { return nil }
        let zero = [Float16](repeating: Float16(-90), count: textureColumns * displayBins)
        tex.replace(region: MTLRegionMake2D(0, 0, textureColumns, displayBins),
                    mipmapLevel: 0,
                    withBytes: zero,
                    bytesPerRow: textureColumns * 2)
        self.spectroTexture = tex
        self.textureColumns = textureColumns
        self.textureRows = displayBins

        let lutBytes = Colormaps.lut(for: .monoBlue)
        let cd = MTLTextureDescriptor()
        cd.textureType = .type1D
        cd.pixelFormat = .rgba8Unorm
        cd.width = 256
        cd.usage = [.shaderRead]
        cd.storageMode = .shared
        guard let cmt = device.makeTexture(descriptor: cd) else { return nil }
        cmt.replace(region: MTLRegionMake1D(0, 256), mipmapLevel: 0, withBytes: lutBytes, bytesPerRow: 0)
        self.colormapTexture = cmt

        let library: MTLLibrary
        if let lib = try? device.makeDefaultLibrary(bundle: .main) {
            library = lib
        } else if let lib = device.makeDefaultLibrary() {
            library = lib
        } else {
            return nil
        }
        guard
            let vsFull = library.makeFunction(name: "vs_fullscreen"),
            let fsSpectro = library.makeFunction(name: "fs_spectrogram"),
            let vsBeat = library.makeFunction(name: "vs_beat"),
            let fsBeat = library.makeFunction(name: "fs_beat"),
            let vsPitch = library.makeFunction(name: "vs_pitch"),
            let fsPitch = library.makeFunction(name: "fs_pitch"),
            let vsHeat = library.makeFunction(name: "vs_heatmap"),
            let fsHeat = library.makeFunction(name: "fs_heatmap")
        else {
            return nil
        }

        func makePipeline(vs: MTLFunction, fs: MTLFunction, blend: Bool = true) throws -> MTLRenderPipelineState {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vs
            pd.fragmentFunction = fs
            pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pd.colorAttachments[0].isBlendingEnabled = blend
            pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pd.colorAttachments[0].sourceAlphaBlendFactor = .one
            pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: pd)
        }

        guard let p1 = try? makePipeline(vs: vsFull, fs: fsSpectro),
              let p2 = try? makePipeline(vs: vsBeat, fs: fsBeat),
              let p3 = try? makePipeline(vs: vsPitch, fs: fsPitch),
              let p4 = try? makePipeline(vs: vsHeat, fs: fsHeat)
        else { return nil }
        self.pipeline = p1
        self.beatPipeline = p2
        self.pitchPipeline = p3
        self.heatmapPipeline = p4

        super.init()
        view.delegate = self
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        view.preferredFramesPerSecond = 120
    }

    func setColormap(_ kind: ColormapKind) {
        let lut = Colormaps.lut(for: kind)
        colormapTexture.replace(region: MTLRegionMake1D(0, 256),
                                mipmapLevel: 0,
                                withBytes: lut,
                                bytesPerRow: 0)
    }

    func append(column: [Float]) {
        guard column.count == textureRows else { return }
        var half = [Float16](repeating: 0, count: textureRows)
        for i in 0..<textureRows { half[i] = Float16(column[i]) }
        let region = MTLRegionMake2D(writeColumn, 0, 1, textureRows)
        spectroTexture.replace(region: region,
                               mipmapLevel: 0,
                               withBytes: half,
                               bytesPerRow: 2)
        writeColumn = (writeColumn + 1) % textureColumns
    }

    func updateBeats(_ markers: [BeatMarker], visibleSecondsCap: Float) {
        let nowHost = mach_absolute_time()
        let secondsPerTick = machSecondsPerTick()
        var verts: [BeatVertexIn] = []
        verts.reserveCapacity(markers.count * 2)
        for m in markers where m.accent != .off {
            let dt = Double(Int64(nowHost) - Int64(m.hostTime)) * secondsPerTick
            if dt < -Double(visibleSecondsCap) * 0.25 || dt > Double(visibleSecondsCap) { continue }
            let timeNorm = 1.0 - dt / Double(visibleSecondsCap)
            let along = Float(timeNorm) * 2.0 - 1.0
            let acc: Float = Float(m.accent.rawValue)
            let trk: Float = Float(m.trackId)
            verts.append(BeatVertexIn(along: along, across: -1, accent: acc, track: trk))
            verts.append(BeatVertexIn(along: along, across:  1, accent: acc, track: trk))
        }
        beatInstanceCount = verts.count / 2
        if verts.isEmpty {
            beatVertexBuffer = nil
            return
        }
        let len = MemoryLayout<BeatVertexIn>.stride * verts.count
        if beatVertexBuffer == nil || beatVertexBuffer!.length < len {
            beatVertexBuffer = device.makeBuffer(length: max(len, 1024), options: .storageModeShared)
        }
        beatVertexBuffer!.contents().copyMemory(from: verts, byteCount: len)
    }

    func updatePitchTrail(_ trail: [PitchEvent], referenceA: Double, transpose: Int) {
        let nowHost = mach_absolute_time()
        let secondsPerTick = machSecondsPerTick()
        let logMin = log(max(1e-3, displayMinHz))
        let logMax = log(max(displayMinHz + 1, displayMaxHz))
        var verts: [PitchVertexIn] = []
        verts.reserveCapacity(trail.count)
        for e in trail where e.f0 > 0 {
            let dt = Double(Int64(nowHost) - Int64(e.hostTime)) * secondsPerTick
            if dt < 0 || dt > Double(visibleSeconds) { continue }
            let timeNorm = 1.0 - dt / Double(visibleSeconds)
            let along = Float(timeNorm) * 2.0 - 1.0
            let lf = log(e.f0)
            let freqNorm = (lf - logMin) / (logMax - logMin)
            if freqNorm < 0 || freqNorm > 1 { continue }
            let across = freqNorm * 2.0 - 1.0
            verts.append(PitchVertexIn(along: along, across: across, clarity: e.clarity))
        }
        pitchVertexCount = verts.count
        if verts.isEmpty {
            pitchVertexBuffer = nil
            return
        }
        let len = MemoryLayout<PitchVertexIn>.stride * verts.count
        if pitchVertexBuffer == nil || pitchVertexBuffer!.length < len {
            pitchVertexBuffer = device.makeBuffer(length: max(len, 1024), options: .storageModeShared)
        }
        pitchVertexBuffer!.contents().copyMemory(from: verts, byteCount: len)
    }

    /// `samples` is an ordered series of (ageSeconds, |cents|/50) for the heatmap band.
    /// Each sample becomes two vertices (across=-1, +1) forming a quad strip.
    func updateHeatmap(samples: [(ageSeconds: Double, magnitude: Float)]) {
        guard heatmapEnabled, !samples.isEmpty else {
            heatmapVertexBuffer = nil
            heatmapVertexCount = 0
            return
        }
        var verts: [HeatmapVertexIn] = []
        verts.reserveCapacity(samples.count * 2)
        for s in samples {
            let timeNorm = 1.0 - s.ageSeconds / Double(visibleSeconds)
            let along = Float(timeNorm) * 2.0 - 1.0
            verts.append(HeatmapVertexIn(along: along, across: -1, magnitude: s.magnitude))
            verts.append(HeatmapVertexIn(along: along, across:  1, magnitude: s.magnitude))
        }
        heatmapVertexCount = verts.count
        let len = MemoryLayout<HeatmapVertexIn>.stride * verts.count
        if heatmapVertexBuffer == nil || heatmapVertexBuffer!.length < len {
            heatmapVertexBuffer = device.makeBuffer(length: max(len, 1024), options: .storageModeShared)
        }
        heatmapVertexBuffer!.contents().copyMemory(from: verts, byteCount: len)
    }

    // Returns the spectrogram texture and its current write head so a snapshot
    // can be made by the export pipeline without touching internal renderer state.
    func snapshotTexture() -> (MTLTexture, Int) { (spectroTexture, writeColumn) }
    func currentVisibleSecondsCap() -> Float { visibleSeconds }

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let cb = queue.makeCommandBuffer()
        else { return }

        uniforms.writeHeadNorm = Float(writeColumn) / Float(textureColumns)
        uniforms.dbFloor = dbFloor
        uniforms.dbCeil = dbCeil
        uniforms.zoomMinLog = log(max(1e-3, displayMinHz))
        uniforms.zoomMaxLog = log(max(displayMinHz + 1, displayMaxHz))
        uniforms.fftMinLog = log(max(1e-3, contentMinHz))
        uniforms.fftMaxLog = log(max(contentMinHz + 1, contentMaxHz))
        uniforms.nowTime = Float(CACurrentMediaTime() - startTime)
        uniforms.visibleSeconds = visibleSeconds
        uniforms.isLandscape = orientation.isLandscape ? 1 : 0
        switch scrubMode {
        case .live: uniforms.scrubOffsetNorm = 0
        case .paused(let off): uniforms.scrubOffsetNorm = Float(off / Double(max(0.001, visibleSeconds)))
        }
        uniforms.showHeatmap = heatmapEnabled ? 1 : 0
        uniforms.bandSizeNorm = 0.06

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "ttuner.spectrogram"

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(spectroTexture, index: 0)
        encoder.setFragmentTexture(colormapTexture, index: 1)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if let bvb = beatVertexBuffer, beatInstanceCount > 0 {
            encoder.setRenderPipelineState(beatPipeline)
            encoder.setVertexBuffer(bvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: beatInstanceCount * 2)
        }

        if let pvb = pitchVertexBuffer, pitchVertexCount > 1 {
            encoder.setRenderPipelineState(pitchPipeline)
            encoder.setVertexBuffer(pvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pitchVertexCount)
        }

        if heatmapEnabled, let hvb = heatmapVertexBuffer, heatmapVertexCount > 1 {
            encoder.setRenderPipelineState(heatmapPipeline)
            encoder.setVertexBuffer(hvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: heatmapVertexCount)
        }

        encoder.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

private let machInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func machSecondsPerTick() -> Double {
    Double(machInfo.numer) / Double(machInfo.denom) / 1.0e9
}
