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
}

private struct BeatVertexIn {
    var along: Float
    var across: Float
    var accent: Float
}

private struct PitchVertexIn {
    var along: Float
    var across: Float
    var clarity: Float
}

/// Manages the Metal pipeline, the ring texture for the spectrogram, and the
/// per-frame uniforms used by `Shaders.metal`. Driven by a `CADisplayLink`.
final class SpectrogramRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private weak var view: MTKView?

    private var spectroTexture: MTLTexture
    private var colormapTexture: MTLTexture
    private var pipeline: MTLRenderPipelineState
    private var beatPipeline: MTLRenderPipelineState
    private var pitchPipeline: MTLRenderPipelineState

    private let textureColumns: Int
    private let textureRows: Int
    private(set) var writeColumn: Int = 0

    private(set) var uniforms = Uniforms()
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    private var beatVertexBuffer: MTLBuffer?
    private var beatInstanceCount: Int = 0
    private var pitchVertexBuffer: MTLBuffer?
    private var pitchVertexCount: Int = 0

    // Public visuals knobs
    var visibleSeconds: Float = 8
    var displayMinHz: Float = 50
    var displayMaxHz: Float = 4_000
    var contentMinHz: Float = 50
    var contentMaxHz: Float = 20_000
    var dbFloor: Float = -90
    var dbCeil: Float = 0
    var orientation: AppOrientation = .portrait
    var scrubMode: ScrubMode = .live

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
        // Initialize to -inf-equivalent (treat as floor)
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
            let fsPitch = library.makeFunction(name: "fs_pitch")
        else {
            return nil
        }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vsFull
        pd.fragmentFunction = fsSpectro
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let spectroPipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.pipeline = spectroPipeline

        let bd = MTLRenderPipelineDescriptor()
        bd.vertexFunction = vsBeat
        bd.fragmentFunction = fsBeat
        bd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        bd.colorAttachments[0].isBlendingEnabled = true
        bd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        guard let beatP = try? device.makeRenderPipelineState(descriptor: bd) else { return nil }
        self.beatPipeline = beatP

        let pd2 = MTLRenderPipelineDescriptor()
        pd2.vertexFunction = vsPitch
        pd2.fragmentFunction = fsPitch
        pd2.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd2.colorAttachments[0].isBlendingEnabled = true
        pd2.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd2.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        guard let pitchP = try? device.makeRenderPipelineState(descriptor: pd2) else { return nil }
        self.pitchPipeline = pitchP

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

    /// Append one spectrum column (display-bin values in dB).
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

    // MARK: - Beat markers
    func updateBeats(_ markers: [BeatMarker], visibleSecondsCap: Float) {
        let nowHost = mach_absolute_time()
        // Precompute mach time → seconds
        let secondsPerTick = machSecondsPerTick()
        var verts: [BeatVertexIn] = []
        verts.reserveCapacity(markers.count * 2)
        for m in markers where m.accent != .off {
            // age in seconds (positive in the past, negative in the future)
            let dt = Double(Int64(nowHost) - Int64(m.hostTime)) * secondsPerTick
            // The marker is visible when 0 <= dt <= visibleSeconds (already on screen)
            // or when -visibleSeconds/4 <= dt < 0 (just-about-to-tick, fades in)
            if dt < -Double(visibleSecondsCap) * 0.25 || dt > Double(visibleSecondsCap) { continue }
            let timeNorm = 1.0 - dt / Double(visibleSecondsCap)
            let along = Float(timeNorm) * 2.0 - 1.0
            let acc: Float = Float(m.accent.rawValue)
            verts.append(BeatVertexIn(along: along, across: -1, accent: acc))
            verts.append(BeatVertexIn(along: along, across:  1, accent: acc))
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

    // MARK: - Pitch trail
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

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let cb = queue.makeCommandBuffer()
        else { return }

        // Refresh uniforms
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

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "ttuner.spectrogram"

        // Pass 1: spectrogram fullscreen
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(spectroTexture, index: 0)
        encoder.setFragmentTexture(colormapTexture, index: 1)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Pass 2: beat markers (line list)
        if let bvb = beatVertexBuffer, beatInstanceCount > 0 {
            encoder.setRenderPipelineState(beatPipeline)
            encoder.setVertexBuffer(bvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 2 verts per marker as a `line` list
            encoder.drawPrimitives(type: .line,
                                   vertexStart: 0,
                                   vertexCount: beatInstanceCount * 2)
        }

        // Pass 3: pitch trail (line strip)
        if let pvb = pitchVertexBuffer, pitchVertexCount > 1 {
            encoder.setRenderPipelineState(pitchPipeline)
            encoder.setVertexBuffer(pvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pitchVertexCount)
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
