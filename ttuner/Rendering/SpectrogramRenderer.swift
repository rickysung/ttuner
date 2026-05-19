import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

private struct Uniforms {
    var writeHeadNorm: Float = 0
    var dbFloor: Float = -45
    var dbCeil: Float = 35
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
    var rmsFloor: Float = -60
    var rmsCeil: Float = -12
    var rmsMaxHalfWidth: Float = 0.22
    var visibleRingFrac: Float = 0.7324  // 8 sec out of ≈10.93 sec ring at 48k/512
    var vignetteStrength: Float = 0.55
    var rmsOpacity: Float = 0.70
    var texelW: Float = 1.0 / 1024.0
    var texelH: Float = 1.0 / 512.0
    var spectroBlur: Float = 1.0
    var scrubOffsetSeconds: Float = 0
    var cameraSemitone: Float = 60
    var semitoneSpacing: Float = 2.0 / 6.0   // half octave across screen
    var pitchInTune: Float = 0
    var emitterX: Float = 0
    var emitterY: Float = -0.66
    var viewAspect: Float = 9.0 / 19.5    // iPhone portrait-ish; refreshed every frame
    var particleSize: Float = 0.018
    var emitterPulse: Float = 0
    var flameSway: Float = 0
    var flameTailMax: Float = 1.6
    var scrubActive: Float = 0
}

private struct PitchDotVertexIn {
    var secondsSinceStart: Float
    var semitone: Float
    var clarity: Float
    var rmsDb: Float
}

private struct BeatVertexIn {
    /// Wall-clock seconds (since renderer start) when this beat was scheduled.
    /// The vertex shader recomputes the screen position from this every frame
    /// so beats slide with the spectrogram between metronome ticks. The
    /// quad's spatial layout is now computed from the per-vertex id +
    /// per-instance id, so no `across` field is needed.
    var secondsSinceStart: Float
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
    private var rmsTexture: MTLTexture
    private var pipeline: MTLRenderPipelineState
    private var beatPipeline: MTLRenderPipelineState
    private var pitchPipeline: MTLRenderPipelineState
    private var heatmapPipeline: MTLRenderPipelineState
    private var rmsBarsPipeline: MTLRenderPipelineState
    private var refGridPipeline: MTLRenderPipelineState
    private var pitchDotPipeline: MTLRenderPipelineState

    // Theme-swappable pipelines. Rebuilt by `applyTheme(_:)` so a new
    // visual skin can take over without touching the core renderer.
    private var emitterPipeline: MTLRenderPipelineState!
    private var particlePipeline: MTLRenderPipelineState!
    private var backgroundPipeline: MTLRenderPipelineState?

    // Particle physics runs on the GPU. Buffer is seeded once on the CPU
    // at init, then becomes GPU-owned for the rest of the session.
    private var particleSimPipeline: MTLComputePipelineState!
    private var particleFrameCounter: UInt32 = 0

    private let library: MTLLibrary
    private var vsFullscreen: MTLFunction
    private var vsParticle: MTLFunction
    private(set) var currentTheme: VisualTheme = .flame

    private let textureColumns: Int
    private let textureRows: Int
    private(set) var writeColumn: Int = 0

    private var uniforms = Uniforms()
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    /// `nowTime` snapshot at the moment the user entered scrub. Used to
    /// freeze the rendered timeline while paused.
    private var scrubAnchorNowTime: Float? = nil
    /// `mach_absolute_time()` snapshot taken at the same instant. Used
    /// by `rebuildPitchDotBuffer` so its CPU-side cull stops removing
    /// points based on wall-clock age while scrubbing.
    private var scrubAnchorHostTime: UInt64? = nil
    /// Smoothed camera at scrub entry. Allows horizontal drag to slide
    /// the camera to neighbouring pitches without losing the snapshot.
    private var scrubAnchorCameraSemitone: Float? = nil
    /// User horizontal-drag offset (semitones). 0 keeps the camera at
    /// the scrub-entry pitch.
    var scrubCameraOffsetSemitones: Float = 0
    /// Scratch buffer for the per-column Float→Float16 conversion. Reused
    /// every frame to avoid re-allocating ~1 KB at ≈94 Hz.
    private var halfScratch: [Float16]

    private var beatVertexBuffer: MTLBuffer?
    private var beatInstanceCount: Int = 0
    private var pitchVertexBuffer: MTLBuffer?
    private var pitchVertexCount: Int = 0
    private var heatmapVertexBuffer: MTLBuffer?
    private var heatmapVertexCount: Int = 0

    private var pitchDotBuffer: MTLBuffer?
    private var pitchDotCount: Int = 0
    private var particleBuffer: MTLBuffer?

    private let particles = ParticleSystem(capacity: 1000)
    /// Smoothed pitch in MIDI semitones — the camera anchor. Updated each
    /// frame via a critically-damped spring so transitions ease in and out.
    private var smoothedSemitone: Float = 60
    private var smoothedVelocity: Float = 0
    private var hasPitch: Bool = false
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    var targetSemitone: Float = 60
    var pitchActive: Bool = false
    var pitchInTuneAmount: Float = 0     // 0..1 (1 = ≤5¢)
    var rmsDb: Float = -60
    /// User-controlled pitch-grid width in semitones (pinch-zoom). The
    /// shader's `semitoneSpacing` = 2 / visibleSemitones, so larger
    /// values = more grid lines on screen and dots compressed
    /// horizontally. Flame geometry is independent of this.
    var visibleSemitones: Float = 6

    /// Mirrors of the shader-side camera so the SwiftUI label overlay can
    /// position note names along the visible pitch grid without going
    /// through the GPU. Updated each draw frame.
    private(set) var publishedCameraSemitone: Float = 60
    private(set) var publishedSemitoneSpacing: Float = 2.0 / 6.0

    private var timelinePoints: [PitchTimelinePoint] = []
    private let timelinePointCapacity = 1500

    var visibleSeconds: Float = 8
    var displayMinHz: Float = 30
    var displayMaxHz: Float = 6_000
    var contentMinHz: Float = 30
    var contentMaxHz: Float = 20_000
    var dbFloor: Float = -45
    var dbCeil: Float = 35
    var orientation: AppOrientation = .portrait
    var scrubMode: ScrubMode = .live
    var heatmapEnabled: Bool = false
    /// Audio hops per second. With the default 1024-column ring this works out
    /// to roughly textureColumns/framesPerSecond ≈ 10.9 seconds of history on
    /// screen at any time. Beat markers and heatmap quads use this to align
    /// their scroll speed with the spectrogram.
    var framesPerSecond: Float = 93.75
    var rmsBarOpacity: Float = 0.70
    var spectroBlur: Float = 1.0
    /// `mach_absolute_time()` value at renderer init, used to convert beat
    /// marker host-times into the same seconds-since-start frame the vertex
    /// shader operates in.
    private let startMach: UInt64 = mach_absolute_time()

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
        self.halfScratch = [Float16](repeating: 0, count: displayBins)

        // 1D r16Float RMS history, one slot per time column. Initialized to
        // rmsFloor so the bar collapses to nothing before any data arrives.
        let rd = MTLTextureDescriptor()
        rd.textureType = .type1D
        rd.pixelFormat = .r16Float
        rd.width = textureColumns
        rd.usage = [.shaderRead]
        rd.storageMode = .shared
        guard let rmsTex = device.makeTexture(descriptor: rd) else { return nil }
        let rmsInit = [Float16](repeating: Float16(-90), count: textureColumns)
        rmsTex.replace(region: MTLRegionMake1D(0, textureColumns),
                       mipmapLevel: 0,
                       withBytes: rmsInit,
                       bytesPerRow: 0)
        self.rmsTexture = rmsTex

        let lutBytes = Colormaps.lut(for: .magma)
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
        self.library = library
        guard
            let vsFull = library.makeFunction(name: "vs_fullscreen"),
            let fsSpectro = library.makeFunction(name: "fs_spectrogram"),
            let vsBeat = library.makeFunction(name: "vs_beat"),
            let fsBeat = library.makeFunction(name: "fs_beat"),
            let vsPitch = library.makeFunction(name: "vs_pitch"),
            let fsPitch = library.makeFunction(name: "fs_pitch"),
            let vsHeat = library.makeFunction(name: "vs_heatmap"),
            let fsHeat = library.makeFunction(name: "fs_heatmap"),
            let fsRmsBars = library.makeFunction(name: "fs_rmsbars"),
            let fsRefGrid = library.makeFunction(name: "fs_refgrid"),
            let vsPitchDot = library.makeFunction(name: "vs_pitchdot"),
            let fsPitchDot = library.makeFunction(name: "fs_pitchdot"),
            let vsPart = library.makeFunction(name: "vs_particle")
        else {
            return nil
        }
        self.vsFullscreen = vsFull
        self.vsParticle = vsPart

        let pixelFormat = view.colorPixelFormat
        func makePipeline(vs: MTLFunction, fs: MTLFunction,
                          additive: Bool = false) throws -> MTLRenderPipelineState {
            return try SpectrogramRenderer.buildPipeline(device: device,
                                                          vs: vs, fs: fs,
                                                          pixelFormat: pixelFormat,
                                                          additive: additive)
        }

        guard let p1 = try? makePipeline(vs: vsFull, fs: fsSpectro),
              let p2 = try? makePipeline(vs: vsBeat, fs: fsBeat),
              let p3 = try? makePipeline(vs: vsPitch, fs: fsPitch),
              let p4 = try? makePipeline(vs: vsHeat, fs: fsHeat),
              let p5 = try? makePipeline(vs: vsFull, fs: fsRmsBars),
              let p6 = try? makePipeline(vs: vsFull, fs: fsRefGrid),
              let p7 = try? makePipeline(vs: vsPitchDot, fs: fsPitchDot, additive: true)
        else { return nil }
        self.pipeline = p1
        self.beatPipeline = p2
        self.pitchPipeline = p3
        self.heatmapPipeline = p4
        self.rmsBarsPipeline = p5
        self.refGridPipeline = p6
        self.pitchDotPipeline = p7

        // Allocate the particle instance buffer up front — the size never
        // changes after init.
        let particleLen = MemoryLayout<ParticleInstance>.stride * particles.capacity
        guard let pb = device.makeBuffer(length: particleLen, options: .storageModeShared) else {
            return nil
        }
        // Seed the buffer once from the CPU-staggered initial pool. After
        // this, the GPU compute kernel owns the data — no more per-frame
        // memcpy from the Swift array (which is no longer modified).
        particles.particles.withUnsafeBufferPointer { src in
            pb.contents().copyMemory(from: src.baseAddress!, byteCount: particleLen)
        }
        self.particleBuffer = pb

        // Compute pipeline for the per-frame physics step.
        guard let simFn = library.makeFunction(name: "simulate_particles"),
              let simPipe = try? device.makeComputePipelineState(function: simFn) else {
            return nil
        }
        self.particleSimPipeline = simPipe

        super.init()
        view.delegate = self
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        // Default theme = Flame. This must succeed (compile-time function
        // names exist), but if a future theme is misspelled we fall back
        // to Flame so the screen is never blank.
        if !applyTheme(.flame) {
            NSLog("ttuner: failed to apply default Flame theme")
        }
    }

    /// Build pipelines for the given theme and swap them in. Safe to call
    /// at runtime; existing pipelines are dropped and rebuilt. Returns
    /// false if any required fragment function is missing — caller can
    /// keep the previous theme on failure.
    @discardableResult
    func applyTheme(_ theme: VisualTheme) -> Bool {
        guard let view = self.view else { return false }
        let pixelFormat = view.colorPixelFormat
        guard let fsEmitter = library.makeFunction(name: theme.emitterFragment),
              let fsParticle = library.makeFunction(name: theme.particleFragment) else {
            NSLog("ttuner: theme '\(theme.id)' missing fragment function(s)")
            return false
        }
        let bgPipeline: MTLRenderPipelineState?
        if let bgName = theme.backgroundFragment {
            guard let fsBg = library.makeFunction(name: bgName),
                  let pipe = try? SpectrogramRenderer.buildPipeline(device: device,
                                                                     vs: vsFullscreen,
                                                                     fs: fsBg,
                                                                     pixelFormat: pixelFormat,
                                                                     additive: false) else {
                NSLog("ttuner: theme '\(theme.id)' background fragment failed")
                return false
            }
            bgPipeline = pipe
        } else {
            bgPipeline = nil
        }
        guard let emitter = try? SpectrogramRenderer.buildPipeline(device: device,
                                                                    vs: vsFullscreen,
                                                                    fs: fsEmitter,
                                                                    pixelFormat: pixelFormat,
                                                                    additive: true),
              let particle = try? SpectrogramRenderer.buildPipeline(device: device,
                                                                     vs: vsParticle,
                                                                     fs: fsParticle,
                                                                     pixelFormat: pixelFormat,
                                                                     additive: true) else {
            NSLog("ttuner: theme '\(theme.id)' pipeline build failed")
            return false
        }
        self.emitterPipeline = emitter
        self.particlePipeline = particle
        self.backgroundPipeline = bgPipeline
        self.currentTheme = theme
        view.clearColor = theme.clearColor
        return true
    }

    /// Encode the per-frame particle physics step into the given command
    /// buffer. The buffer is mutated in place; the next render pass in
    /// the same command buffer will see the updated state.
    private func dispatchParticleStep(commandBuffer cb: MTLCommandBuffer,
                                       buffer pb: MTLBuffer,
                                       dt: Float) {
        guard let encoder = cb.makeComputeCommandEncoder() else { return }
        encoder.label = "ttuner.particles.simulate"
        encoder.setComputePipelineState(particleSimPipeline)
        encoder.setBuffer(pb, offset: 0, index: 0)

        let pitchScale: Float = particles.pitchActive ? 1.0 : 0.10
        let brownianScale: Float = particles.pitchActive ? 1.0 : 1.6
        var sim = ParticleSimUniforms(
            dt: dt,
            frameCounter: particleFrameCounter,
            activeCount: UInt32(particles.activeCount(forIntensity: particles.emitterIntensity)),
            capacity: UInt32(particles.capacity),
            emitterX: particles.emitterX,
            emitterY: particles.emitterY,
            cameraSemitone: particles.cameraSemitone,
            semitoneSpacing: particles.semitoneSpacing,
            upwardBias: particles.upwardBias,
            brownian: particles.brownianStrength * brownianScale,
            attract: particles.attractStrength * pitchScale,
            boost: particles.pitchActive ? particles.boostStrength : 0,
            boostRadius: particles.boostRadius,
            // When pitch is detected, the field flips: gravity now lifts
            // instead of pulls down so the cloud rockets upward, layered
            // on top of the spring/boost forces that pull particles onto
            // the active pitch line. Silence ⇒ normal downward gravity
            // and the flame settles into a flicker.
            globalGravity: particles.pitchActive ? -particles.globalGravity
                                                  : particles.globalGravity,
            lifeDecay: particles.lifeDecay,
            damp: 1.0 - min(1.0, 0.30 * dt),
            emitterIntensity: particles.emitterIntensity
        )
        encoder.setBytes(&sim, length: MemoryLayout<ParticleSimUniforms>.stride, index: 1)

        let threadsPerThreadgroup = MTLSize(width: 64, height: 1, depth: 1)
        let threadgroups = MTLSize(width: (particles.capacity + 63) / 64,
                                   height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        particleFrameCounter &+= 1
    }

    private static func buildPipeline(device: MTLDevice,
                                       vs: MTLFunction, fs: MTLFunction,
                                       pixelFormat: MTLPixelFormat,
                                       additive: Bool) throws -> MTLRenderPipelineState {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = pixelFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        if additive {
            pd.colorAttachments[0].sourceRGBBlendFactor = .one
            pd.colorAttachments[0].destinationRGBBlendFactor = .one
            pd.colorAttachments[0].sourceAlphaBlendFactor = .one
            pd.colorAttachments[0].destinationAlphaBlendFactor = .one
        } else {
            pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pd.colorAttachments[0].sourceAlphaBlendFactor = .one
            pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: pd)
    }

    func setColormap(_ kind: ColormapKind) {
        let lut = Colormaps.lut(for: kind)
        colormapTexture.replace(region: MTLRegionMake1D(0, 256),
                                mipmapLevel: 0,
                                withBytes: lut,
                                bytesPerRow: 0)
    }

    func append(column: [Float], rmsDb: Float) {
        guard column.count == textureRows else { return }
        column.withUnsafeBufferPointer { src in
            halfScratch.withUnsafeMutableBufferPointer { dst in
                for i in 0..<textureRows { dst[i] = Float16(src[i]) }
            }
        }
        let region = MTLRegionMake2D(writeColumn, 0, 1, textureRows)
        halfScratch.withUnsafeBufferPointer { p in
            spectroTexture.replace(region: region,
                                   mipmapLevel: 0,
                                   withBytes: p.baseAddress!,
                                   bytesPerRow: 2)
        }
        // Write the RMS sample into the same column index so the bar pass
        // and the spectrogram stay perfectly aligned in time.
        var rms16 = Float16(rmsDb)
        rmsTexture.replace(region: MTLRegionMake1D(writeColumn, 1),
                           mipmapLevel: 0,
                           withBytes: &rms16,
                           bytesPerRow: 0)
        writeColumn = (writeColumn + 1) % textureColumns
    }

    func updateBeats(_ markers: [BeatMarker], visibleSecondsCap: Float) {
        let secondsPerTick = machSecondsPerTick()
        // Convert each marker's host-time into "seconds since renderer
        // started" so the vertex shader can place it relative to U.nowTime
        // every frame. Keep markers within roughly the visible window plus a
        // little slack on either side — older or future ticks are off-screen.
        let span = max(0.001, Double(visibleSecondsCap))
        var verts: [BeatVertexIn] = []
        verts.reserveCapacity(markers.count)
        for m in markers where m.accent != .off {
            let marker_dtTicks = Int64(m.hostTime) - Int64(startMach)
            let markerSecondsSinceStart = Float(Double(marker_dtTicks) * secondsPerTick)
            // Skip markers that can't possibly be on screen even with the
            // largest reasonable scrub. The shader will further clip.
            let dtNow = Double(Int64(mach_absolute_time()) - Int64(m.hostTime)) * secondsPerTick
            // Negative dtNow = beat is in the future. Keep enough headroom
            // for the metronome's lookahead so future markers approach the
            // flame from below before their audio fires.
            if dtNow < -2.5 || dtNow > span * 1.5 { continue }
            verts.append(BeatVertexIn(
                secondsSinceStart: markerSecondsSinceStart,
                accent: Float(m.accent.rawValue),
                track: Float(m.trackId)))
        }
        beatInstanceCount = verts.count
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

    /// Append a pitch detection sample to the timeline.
    func appendPitchPoint(hostTime: UInt64, semitone: Float, clarity: Float, rmsDb: Float) {
        timelinePoints.append(PitchTimelinePoint(
            hostTime: hostTime,
            semitone: semitone,
            clarity: clarity,
            rmsDb: rmsDb
        ))
        if timelinePoints.count > timelinePointCapacity {
            timelinePoints.removeFirst(timelinePoints.count - timelinePointCapacity)
        }
    }

    /// Update the live pitch reading driving the camera and particle force field.
    func updateCurrentPitch(semitone: Float?, clarity: Float, rmsDb: Float) {
        if let s = semitone {
            targetSemitone = s
            pitchActive = true
            // Cents from nearest integer semitone in [0, 50].
            let frac = s - floor(s)
            let cents = (frac > 0.5 ? (1.0 - frac) : frac) * 100.0
            // 1 = perfectly in tune (≤5¢), 0 = ≥30¢ off
            let inTuneT = max(0, 1.0 - max(0, cents - 5.0) / 25.0)
            // Light low-pass so colors don't strobe at clarity edges
            pitchInTuneAmount = pitchInTuneAmount * 0.7 + inTuneT * 0.3
        } else {
            pitchActive = false
            // No pitch: ease the color back to neutral over time
            pitchInTuneAmount *= 0.95
        }
        self.rmsDb = rmsDb
        _ = clarity
    }

    // MARK: - MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let cb = queue.makeCommandBuffer()
        else { return }

        // Frame timing for particle/camera integration.
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, max(1.0/240.0, now - lastFrameTime)))
        lastFrameTime = now

        // Critically-damped spring → S-curve transition between notes:
        // zero velocity at start, peaks mid-way, decelerates to rest. Much
        // gentler than the previous exp-decay which kicked off at full speed.
        if pitchActive {
            let omega: Float = 6.0   // ~0.7 s settle for a one-octave jump
            let displacement = smoothedSemitone - targetSemitone
            let accel = -omega * omega * displacement - 2.0 * omega * smoothedVelocity
            smoothedVelocity += accel * dt
            smoothedSemitone += smoothedVelocity * dt
        } else {
            // Bleed off any leftover velocity so the next note starts the
            // spring fresh (zero velocity → clean ease-in).
            smoothedVelocity *= max(0.0, 1.0 - dt * 4.0)
        }

        // Viewport aspect (width / height) — needed for round particles.
        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : (9.0/19.5)

        uniforms.writeHeadNorm = Float(writeColumn) / Float(textureColumns)
        uniforms.dbFloor = dbFloor
        uniforms.dbCeil = dbCeil
        uniforms.zoomMinLog = log(max(1e-3, displayMinHz))
        uniforms.zoomMaxLog = log(max(displayMinHz + 1, displayMaxHz))
        uniforms.fftMinLog = log(max(1e-3, contentMinHz))
        uniforms.fftMaxLog = log(max(contentMinHz + 1, contentMaxHz))
        uniforms.nowTime = Float(now - startTime)
        uniforms.visibleSeconds = visibleSeconds
        uniforms.isLandscape = orientation.isLandscape ? 1 : 0
        switch scrubMode {
        case .live:
            uniforms.scrubOffsetNorm = 0
            uniforms.scrubOffsetSeconds = 0
            uniforms.scrubActive = 0
            scrubAnchorNowTime = nil
            scrubAnchorHostTime = nil
            scrubAnchorCameraSemitone = nil
        case .paused(let userDrag):
            // Anchor the rendered "now" at the moment the user entered
            // scrub. Without this, the shader sees nowTime keep ticking
            // forward while scrubOffsetSeconds (the finger position)
            // stays put, so dots and beats scroll past the freeze line
            // even though the user is paused.
            //
            // effectiveNow_desired = anchor - userDrag
            // Shader: effectiveNow = nowTime - scrubOffsetSeconds
            // ⇒ scrubOffsetSeconds = (nowTime - anchor) + userDrag.
            let nowTime = uniforms.nowTime
            if scrubAnchorNowTime == nil {
                scrubAnchorNowTime = nowTime
                scrubAnchorHostTime = mach_absolute_time()
                scrubAnchorCameraSemitone = smoothedSemitone
            }
            let anchor = scrubAnchorNowTime ?? nowTime
            uniforms.scrubOffsetSeconds = (nowTime - anchor) + Float(userDrag)
            uniforms.scrubActive = 1
        }
        // In live mode the camera tracks live pitch. In scrub mode it
        // pivots around the anchor + user's horizontal drag so they can
        // glance left/right at neighbouring pitches without losing the
        // time-snapshot view.
        if let anchor = scrubAnchorCameraSemitone, !scrubMode.isLive {
            uniforms.cameraSemitone = anchor + scrubCameraOffsetSemitones
        } else {
            uniforms.cameraSemitone = smoothedSemitone
        }
        // Pitch-grid width driven by pinch-zoom. Default 6 (half octave,
        // tightest view) → max 24 (two octaves). Spacing in NDC.x per
        // semitone is the inverse: 2 NDC across screen / N semitones.
        uniforms.semitoneSpacing = 2.0 / max(1, visibleSemitones)
        publishedCameraSemitone = uniforms.cameraSemitone
        publishedSemitoneSpacing = uniforms.semitoneSpacing
        uniforms.pitchInTune = pitchActive ? pitchInTuneAmount : 0
        // Pitch-driven sway routed through `flameSway` so it only bends
        // the *tail* — the fireball base stays anchored. sin(2π · cents)
        // glides smoothly across both integer boundaries and ±50¢ midpoints.
        let centsFrac = smoothedSemitone - smoothedSemitone.rounded()
        let leanCurve = sinf(centsFrac * 2.0 * .pi)
        let baseLean = -leanCurve * 0.040
        // Velocity kick: spring velocity peaks once during a transition
        // then decays — read by the eye as a one-shot wobble that settles.
        let velKick = -smoothedVelocity * 0.012
        let clampedKick = max(-0.025, min(0.025, velKick))
        uniforms.flameSway = baseLean + clampedKick
        // Anchor the flame at the horizontal center; the shader applies
        // every horizontal motion as a tail-weighted offset around this.
        uniforms.emitterX = 0
        // Emitter sits just above the metronome card. NDC y = -1 is bottom.
        uniforms.emitterY = orientation.isLandscape ? 0 : -0.66
        uniforms.viewAspect = aspect
        uniforms.particleSize = 0.024
        // Audio-driven brightness for the emitter orb.
        let rmsNorm = max(0, min(1, (rmsDb + 60) / 50))
        uniforms.emitterPulse = rmsNorm
        // Louder = longer tongue of flame. 1.3 at silence (squat fireball),
        // 2.4 at peak (lean, lapping tongue). Power < 1 keeps the curve
        // responsive in the comfortable mid-volume zone instead of only at
        // peaks.
        uniforms.flameTailMax = 1.3 + 1.1 * powf(rmsNorm, 0.6)

        // Sync the particle params for this frame. The compute kernel
        // reads these via SimUniforms; the CPU-side fields exist only as
        // a single place to store the tunables (init, future per-theme
        // tweaks, etc.) — the simulation itself runs entirely on GPU.
        particles.cameraSemitone = smoothedSemitone
        particles.semitoneSpacing = uniforms.semitoneSpacing
        particles.emitterX = uniforms.emitterX
        particles.emitterY = uniforms.emitterY
        particles.inTuneAmount = uniforms.pitchInTune
        particles.emitterIntensity = rmsNorm
        particles.pitchActive = pitchActive

        // Dispatch the particle physics step on the GPU before we open the
        // render encoder. Metal serializes encoders within a command
        // buffer, so the render pass sees the updated buffer.
        if let pb = particleBuffer {
            dispatchParticleStep(commandBuffer: cb, buffer: pb, dt: Float(dt))
        }

        // Build pitch-dot vertex buffer.
        rebuildPitchDotBuffer()

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "ttuner.timeline"
        var u = uniforms

        // 0. Theme background (only if the theme defines one).
        // For Flame this is skipped — the cleared color attachment is
        // already the expected solid black, so the output is identical
        // to the pre-refactor code path.
        if let bg = backgroundPipeline {
            encoder.setRenderPipelineState(bg)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 1. Reference semitone grid (very subtle hairlines)
        encoder.setRenderPipelineState(refGridPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 2. Beat markers — instanced soft-capsule quads (4 verts/instance,
        // triangle strip). Vignette + Gaussian thickness handled in fs_beat.
        if let bvb = beatVertexBuffer, beatInstanceCount > 0 {
            encoder.setRenderPipelineState(beatPipeline)
            encoder.setVertexBuffer(bvb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip,
                                   vertexStart: 0,
                                   vertexCount: 4,
                                   instanceCount: beatInstanceCount)
        }

        // 3. Pitch timeline dots
        if let pdb = pitchDotBuffer, pitchDotCount > 0 {
            encoder.setRenderPipelineState(pitchDotPipeline)
            encoder.setVertexBuffer(pdb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pitchDotCount)
        }

        // 4. Emitter orb
        encoder.setRenderPipelineState(emitterPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 5. Particles (additive — they pile up into a glow)
        if let pb = particleBuffer {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(pb, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: particles.capacity)
        }

        encoder.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func rebuildPitchDotBuffer() {
        guard !timelinePoints.isEmpty else {
            pitchDotCount = 0
            return
        }
        // Cull points older than the visible window (plus a bit of slack
        // for upcoming history scrubs). While the user is scrubbing the
        // "now" reference must freeze too — otherwise dots near the
        // visible-edge keep dropping off even though the shader has
        // them anchored.
        let nowHost: UInt64 = scrubAnchorHostTime ?? mach_absolute_time()
        let secondsPerTick = machSecondsPerTick()
        let cutoff = Double(visibleSeconds) * 1.6
        var verts: [PitchDotVertexIn] = []
        verts.reserveCapacity(timelinePoints.count)
        for p in timelinePoints {
            let dt = Double(Int64(nowHost) - Int64(p.hostTime)) * secondsPerTick
            if dt > cutoff { continue }
            let markerSecondsSinceStart = Float(Double(Int64(p.hostTime) - Int64(startMach)) * secondsPerTick)
            verts.append(PitchDotVertexIn(
                secondsSinceStart: markerSecondsSinceStart,
                semitone: p.semitone,
                clarity: p.clarity,
                rmsDb: p.rmsDb
            ))
        }
        pitchDotCount = verts.count
        if verts.isEmpty {
            pitchDotBuffer = nil
            return
        }
        let len = MemoryLayout<PitchDotVertexIn>.stride * verts.count
        if pitchDotBuffer == nil || pitchDotBuffer!.length < len {
            pitchDotBuffer = device.makeBuffer(length: max(len, 1024), options: .storageModeShared)
        }
        pitchDotBuffer!.contents().copyMemory(from: verts, byteCount: len)
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
