import AppKit
import MetalKit
import QuartzCore
import FractalKit
import CFractal

/// Drives the interactive view. Compute passes (a budgeted preview while the camera moves, then
/// full-resolution tiles and anti-aliasing samples while it rests) run one at a time on the main
/// queue and publish finished images into a front buffer. Presentation runs on its own queue every
/// display frame and reprojects the latest finished image to the current camera, so motion stays at
/// display rate however long the GPU needs for a pass.
final class LiveRenderer: NSObject, MTKViewDelegate {
    let engine: Engine
    let camera: Camera
    private let gpu = GPU.shared
    private let presentQueue: MTLCommandQueue

    // MARK: Inputs (main thread)

    var formula = Formula() { didSet { if formula != oldValue { sceneVersion += 1 } } }
    var iter = IterationSettings() { didSet { if iter != oldValue { sceneVersion += 1 } } }
    var color = ColorSettings() { didSet { if color != oldValue { colorVersion += 1 } } }
    /// Anti-aliasing samples accumulated while the view rests.
    var samplesPerPixel = 16 { didSet { if samplesPerPixel != oldValue { colorVersion += 1 } } }
    /// GPU time a pass may take while the camera moves, in milliseconds.
    var frameBudgetMs = 7.0
    var paletteBlend: Engine.PaletteBlend?
    /// EDR headroom when HDR output is on (nil: standard range).
    var hdrHeadroom: Float? { didSet { if hdrHeadroom != oldValue { presentedFrontVersion = -1 } } }
    private(set) var sceneVersion = 0
    private(set) var colorVersion = 0
    /// Set when the next preview should snap the colours to its view instead of moving them with the zoom.
    var snapColors = true

    /// Reported to the HUD roughly ten times a second.
    var onStatus: ((Status) -> Void)?
    /// Auto-iteration proposals (main thread).
    var onIterationProposal: ((Int) -> Void)?
    /// Called at the start of every display frame with the elapsed time.
    var onFrame: ((Double) -> Void)?
    /// Receives every presented frame while set; setting one presents at once, so it gets a first frame.
    var recorder: LiveRecorder? { didSet { presentedFrontVersion = -1 } }
    /// Called when the drawable changes size while recording (the movie's size is fixed).
    var onRecordingInterrupted: (() -> Void)?
    /// Set to receive the next preview's iterations via `onProbe` (main thread).
    var probeRequested = false
    var onProbe: ((Probe) -> Void)?

    /// Current drawable size in pixels (at least 1 x 1), for converting pointer positions.
    var drawableSize: SIMD2<Int> { size.x > 0 ? size : SIMD2(1, 1) }

    /// Where the progressive rendering of the current view stands (named for the HUD).
    enum Stage: String {
        case preparing = "Preparing", refining = "Refining", smoothing = "Smoothing", done = "Done"
    }

    struct Status {
        var fps: Double
        var gpuMs: Double
        var stage: Stage
        var progress: Double
        var maxIter: Int
        var view: Viewport
        var perturbed: Bool
        var referenceProgress: Double?
        var samples: Int
        /// Effective iterations per second of GPU time over the last compute passes.
        var iterationRate: Double
    }

    /// Coarse copy of the latest preview's escape iterations, for steering the autopilot.
    struct Probe {
        var width: Int
        var height: Int
        var view: Viewport
        var drawable: SIMD2<Int>
        var iterations: [UInt32]
    }

    // MARK: Surfaces

    private var size = SIMD2<Int>(0, 0)
    private var previewGBuffer: MTLBuffer?
    private var fullGBuffer: MTLBuffer?
    private var jitteredGBuffer: MTLBuffer?
    private var previewImage: MTLTexture?
    /// Working image of the compute passes (sums anti-aliasing samples).
    private var accumulator: MTLTexture?
    /// Finished images: `finished[front]` is shown, the other receives the next pass.
    private var finished: [MTLTexture] = []
    private var front = 0
    /// The view the front image shows.
    private var frontView: Viewport?
    private var frontVersion = 0
    private var presentedFrontVersion = -1
    private var presentedCameraVersion = -1
    private var probeBuffer: MTLBuffer?
    /// Incremented when surfaces are reallocated; passes encoded for older surfaces don't publish.
    private var surfaceGeneration = 0

    // MARK: Progressive state (compute side)

    private var stage = Stage.preparing
    /// The view the preview and the passes refining it render.
    private var passView: Viewport?
    /// Size of the preview in the working image; zero once it is at full resolution.
    private var previewSize = SIMD2<Int>(0, 0)
    private var previewScale = 1.0
    private var tiles: [SIMD2<Int>] = []
    private var nextTile = 0
    private let tileSize = 128
    /// One flag per tile, set once the full-resolution pass has computed it.
    private var tileDone: MTLBuffer?
    private var nextSample = 0
    private var accumulatedSamples = 0
    private var needsPreview = true
    private var renderedSceneVersion = -1
    private var renderedCameraVersion = -1
    private var renderedColorVersion = -1
    private var lastPlanPerturbed = false
    /// Zoom of the view that last moved the colour origin.
    private var colorLog2Radius = 0.0
    private var computeInFlight = false
    private var iterationCommandBuffer: MTLCommandBuffer?
    /// Replaces the iteration encoder when refinement tiles run concurrently.
    private var concurrentEncoder: MTLComputeCommandEncoder?
    /// Cycle detection costs time on every step: it is compiled in only while the view may contain interior.
    private var interiorLikely = true

    // MARK: Timing

    /// GPU cost per million samples; pessimistic until measured, as the first view may be
    /// arbitrarily expensive (e.g. a restored session).
    private var msPerMegasample = 500.0
    private var costMeasured = false
    /// Serial latency of a pass's slowest samples.
    private var tailMs = 1.0
    private var lastFrameTime = CACurrentMediaTime()
    private var presentTimes: [Double] = []
    private var shownFps = 0.0
    private var lastStatusTime = 0.0
    private var lastGpuMs = 0.0
    private var lastIterationChange = 0.0
    private var iterationRate = 0.0
    private let presentSlots = DispatchSemaphore(value: 2)

    init(engine: Engine, camera: Camera) {
        self.engine = engine
        self.camera = camera
        presentQueue = GPU.shared.device.makeCommandQueue()!
        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsPreview = true
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        defer {
            let cpuMs = (CACurrentMediaTime() - now) * 1000
            if recordFrames && cpuMs > 12 { slowFrames.append((now, cpuMs, lastWorkNote)) }
        }
        let dt = min(now - lastFrameTime, 0.05)
        lastFrameTime = now
        onFrame?(dt)
        (view as? FractalMTKView)?.syncOutputFormat()
        let drawableSize = SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height))
        guard drawableSize.x > 0, drawableSize.y > 0 else { return }
        if drawableSize != size { resize(drawableSize) }

        camera.flipY = formula.family.flipY
        _ = camera.update(dt: dt, width: size.x, height: size.y)
        if !computeInFlight { submitCompute() }
        present(in: view, now: now)
        reportStatus(now: now)
    }

    /// Renders the current view afresh (e.g. once a reference orbit has been computed).
    func invalidate() { needsPreview = true }

    /// Forces a recolour with the current settings (e.g. after a palette cross-fade ends).
    func recolor() { colorVersion += 1 }

    /// True when the view is fully refined (for scripted snapshots).
    var isSettled: Bool { stage == .done && !camera.isAnimating && !needsPreview && !computeInFlight }

    // MARK: Compute passes

    private enum Work { case preview, refine, recolor }

    /// Encodes and commits the next compute pass, if there is work to do. Iteration and colouring go
    /// into separate command buffers, so the colour pass can publish while the next iteration runs.
    private func submitCompute() {
        let moved = camera.version != renderedCameraVersion
        let work: Work
        if moved || sceneVersion != renderedSceneVersion || needsPreview {
            work = .preview
        } else if colorVersion != renderedColorVersion || paletteBlend != nil {
            work = .recolor
        } else if stage == .refining || stage == .smoothing {
            work = .refine
        } else {
            return
        }
        lastWorkNote = "\(work)"
        guard let iterationCommandBuffer = engine.queue.makeCommandBuffer(),
              let iterationEncoder = iterationCommandBuffer.makeComputeCommandEncoder(),
              let colorCommandBuffer = engine.queue.makeCommandBuffer(),
              let colorEncoder = colorCommandBuffer.makeComputeCommandEncoder() else { return }
        self.iterationCommandBuffer = iterationCommandBuffer
        var iteratedSamples = 0
        var statsSlot: UInt32?
        let sceneAtEncode = sceneVersion
        var produced = true

        switch work {
        case .preview:
            let preview = encodePreview(iterating: iterationEncoder, coloring: colorEncoder, view: camera.view,
                                        moving: moved || camera.isAnimating)
            iteratedSamples = preview.samples
            statsSlot = preview.slot
            produced = preview.samples > 0
        case .recolor:
            encodeRecolor(coloring: colorEncoder)
        case .refine:
            iteratedSamples = encodeRefinement(iterating: iterationEncoder, coloring: colorEncoder)
            produced = iteratedSamples > 0 || stage == .done
        }
        (concurrentEncoder ?? iterationEncoder).endEncoding()
        concurrentEncoder = nil
        self.iterationCommandBuffer = nil
        colorEncoder.endEncoding()

        let probe = work == .preview && produced && probeRequested ? encodeProbeCopy(into: colorCommandBuffer) : nil

        // Publish the working image into the back buffer.
        let back = 1 - front
        let publishedView = passView
        if produced, let accumulator, finished.count == 2, let blit = colorCommandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: accumulator, to: finished[back])
            blit.endEncoding()
        }

        let totalSamples = size.x * size.y
        // within the scale hysteresis of the smallest preview
        let smallest = work == .preview && previewScale < LiveRenderer.smallestPreview * 1.13
        let submitTime = CACurrentMediaTime()
        let note = "\(work) scale \(String(format: "%.2f", previewScale)) iter \(iter.maxIter)"
        iterationCommandBuffer.addCompletedHandler { [weak self] completed in
            let ms = (completed.gpuEndTime - completed.gpuStartTime) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if recordFrames { passLog.append((submitTime, ms, iteratedSamples, note)) }
                lastGpuMs = ms
                learnCost(ms: ms, samples: iteratedSamples, total: totalSamples)
                guard let statsSlot else { return }
                let stats = engine.readStats(statsSlot)
                // interior: detected cycles, or samples stuck at the limit
                interiorLikely = Double(stats.interior + stats.unresolved) > Double(iteratedSamples) * 0.002
                if ms > 0.5 { iterationRate = iterationRate * 0.7 + Double(stats.iterations) / (ms / 1000) * 0.3 }
                if sceneAtEncode == sceneVersion { tuneIterations(stats: stats, samples: iteratedSamples, ms: ms, smallest: smallest) }
            }
        }
        let drawable = size
        let generation = surfaceGeneration
        colorCommandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let probe, let buffer = probeBuffer, generation == surfaceGeneration {
                    let words = buffer.contents().assumingMemoryBound(to: UInt32.self)
                    let iterations = (0..<(probe.width * probe.height)).map { words[$0 * 4] }
                    onProbe?(Probe(width: probe.width, height: probe.height, view: probe.view, drawable: drawable,
                                   iterations: iterations))
                }
                computeInFlight = false
                if produced && finished.count == 2 && generation == surfaceGeneration {
                    front = back
                    frontView = publishedView
                    frontVersion += 1
                }
            }
        }
        computeInFlight = true
        iterationCommandBuffer.commit()
        colorCommandBuffer.commit()
    }

    /// Smallest preview scale (fraction of the drawable per axis).
    static let smallestPreview = 0.12

    private func scene(_ view: Viewport) -> FractalScene { FractalScene(formula: formula, view: view, iter: iter) }

    /// Renders the whole view at a resolution that fits the frame budget.
    private func encodePreview(iterating iterationEncoder: MTLComputeCommandEncoder,
                               coloring colorEncoder: MTLComputeCommandEncoder, view: Viewport,
                               moving: Bool) -> (samples: Int, slot: UInt32?) {
        let affordableSamples = max(frameBudgetMs - tailMs, 0.5) / max(msPerMegasample, 1e-6) * 1e6
        let scale = min(1, max(LiveRenderer.smallestPreview, sqrt(affordableSamples / Double(size.x * size.y))))
        // hysteresis, so that the preview does not flicker between sizes
        if abs(scale - previewScale) / previewScale > 0.12 || scale == 1 { previewScale = scale }
        if !moving && previewScale > 0.7 { previewScale = 1 }
        let width = max(8, Int(Double(size.x) * previewScale)), height = max(8, Int(Double(size.y) * previewScale))

        let slot = engine.nextStatsSlot()
        guard let plan = engine.makePlan(scene: scene(view), grid: Engine.Grid(width: width, height: height),
                                         encoder: iterationEncoder, blocking: false,
                                         focus: camera.focus(width: size.x, height: size.y), statsSlot: slot,
                                         exclusive: true, interior: interiorLikely),
              let previewGBuffer, let fullGBuffer, let accumulator, let previewImage else {
            needsPreview = true   // reference still computing: keep reprojecting the last image
            return (0, nil)
        }
        needsPreview = false
        renderedCameraVersion = camera.version
        lastPlanPerturbed = plan.perturbed
        let fullResolution = width == size.x && height == size.y
        let gBufferSize = SIMD2(UInt32(width), UInt32(height))
        engine.encodeStatsReset(iterationEncoder, slot: slot)
        engine.encodeIterate(iterationEncoder, plan: plan, into: fullResolution ? fullGBuffer : previewGBuffer,
                             origin: .zero, size: gBufferSize, bufferOrigin: .zero, bufferStride: UInt32(width))
        // Colours move with the zoom only, so they hold at rest and while panning; jumps snap them.
        // A flight's arrival settles them faster, so a place is reached with the colours it snaps to.
        let arriving = (camera.flightProgress ?? 0) > 0.8
        let zoomed = (view.log2Radius - colorLog2Radius) * (arriving ? 4 : 1)
        engine.encodeColorOrigin(iterationEncoder, slot: slot, zoomed: snapColors ? nil : zoomed)
        colorLog2Radius = view.log2Radius
        snapColors = false
        let outputSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if fullResolution {
            engine.encodeColorize(colorEncoder, into: accumulator, from: .init(buffer: fullGBuffer, size: outputSize),
                                  fallback: nil, color: color, blend: paletteBlend, accumulate: false, size: outputSize)
        } else {
            engine.encodeShade(colorEncoder, from: .init(buffer: previewGBuffer, size: gBufferSize), into: previewImage,
                               color: color, blend: paletteBlend)
            engine.encodeUpsample(colorEncoder, from: previewImage, size: gBufferSize, into: accumulator,
                                  outputSize: outputSize)
        }
        accumulatedSamples = 1
        passView = view
        renderedSceneVersion = sceneVersion
        renderedColorVersion = colorVersion
        nextTile = 0
        if fullResolution {
            previewSize = .zero
            startSmoothing()
        } else {
            previewSize = SIMD2(width, height)
            stage = .refining
            memset(tileDone!.contents(), 0, tileDone!.length)
        }
        return (width * height, slot)
    }

    /// Continues the full-resolution pass or the next anti-aliasing sample within the frame budget.
    private func encodeRefinement(iterating iterationEncoder: MTLComputeCommandEncoder,
                                  coloring colorEncoder: MTLComputeCommandEncoder) -> Int {
        guard let view = passView, let accumulator, let fullGBuffer, let jitteredGBuffer, let previewImage else { return 0 }
        let jitter = stage == .smoothing ? Engine.jitter(nextSample) : .zero
        let slot = engine.nextStatsSlot()
        guard let plan = engine.makePlan(scene: scene(view), grid: Engine.Grid(width: size.x, height: size.y, jitter: jitter),
                                         encoder: iterationEncoder, blocking: false, statsSlot: slot, exclusive: true,
                                         interior: interiorLikely) else { return 0 }
        let target = stage == .smoothing ? jitteredGBuffer : fullGBuffer
        // Tiles write disjoint regions, so they run concurrently and share the slow-sample tail.
        iterationEncoder.endEncoding()
        guard let tileEncoder = iterationCommandBuffer?.makeComputeCommandEncoder(dispatchType: .concurrent) else { return 0 }
        concurrentEncoder = tileEncoder
        let msPerTile = msPerMegasample * Double(tileSize * tileSize) / 1e6
        var affordableTiles = max(1, Int(max(frameBudgetMs - tailMs, 0.5) / max(msPerTile, 1e-4)))
        var samples = 0
        let done = tileDone!.contents().assumingMemoryBound(to: UInt32.self)
        while affordableTiles > 0 && nextTile < tiles.count {
            let tile = tiles[nextTile]
            let width = min(tileSize, size.x - tile.x), height = min(tileSize, size.y - tile.y)
            engine.encodeIterate(tileEncoder, plan: plan, into: target, origin: SIMD2(UInt32(tile.x), UInt32(tile.y)),
                                 size: SIMD2(UInt32(width), UInt32(height)), bufferOrigin: .zero,
                                 bufferStride: UInt32(size.x))
            if stage == .refining { done[tileIndex(tile)] = 1 }
            samples += width * height
            nextTile += 1
            affordableTiles -= 1
        }
        let outputSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if stage == .refining {
            let complete = nextTile >= tiles.count
            let fallback = Engine.TileFallback(preview: previewImage, previewSize: SIMD2(UInt32(previewSize.x), UInt32(previewSize.y)),
                                               tileDone: tileDone!, grid: tileGrid, tileSize: UInt32(tileSize))
            engine.encodeColorize(colorEncoder, into: accumulator, from: .init(buffer: fullGBuffer, size: outputSize),
                                  fallback: complete ? nil : fallback, color: color, blend: paletteBlend,
                                  accumulate: false, size: outputSize)
            accumulatedSamples = 1
            if complete { startSmoothing() }
        } else if nextTile >= tiles.count {
            engine.encodeColorize(colorEncoder, into: accumulator, from: .init(buffer: jitteredGBuffer, size: outputSize),
                                  fallback: nil, color: color, blend: paletteBlend, accumulate: true, size: outputSize)
            accumulatedSamples += 1
            nextSample += 1
            nextTile = 0
            if nextSample >= samplesPerPixel { stage = .done }
        }
        return samples
    }

    /// Recolours the best finished G-buffer after a palette or shading change; anti-aliasing restarts.
    private func encodeRecolor(coloring colorEncoder: MTLComputeCommandEncoder) {
        guard let accumulator else { return }
        let outputSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if stage == .smoothing || stage == .done, let fullGBuffer {
            engine.encodeColorize(colorEncoder, into: accumulator, from: .init(buffer: fullGBuffer, size: outputSize),
                                  fallback: nil, color: color, blend: paletteBlend, accumulate: false, size: outputSize)
            accumulatedSamples = 1
            if samplesPerPixel > 1 {
                stage = .smoothing
                nextSample = 1
                nextTile = 0
            }
        } else if let previewGBuffer, let previewImage, previewSize.x > 0 {
            let gBufferSize = SIMD2(UInt32(previewSize.x), UInt32(previewSize.y))
            engine.encodeShade(colorEncoder, from: .init(buffer: previewGBuffer, size: gBufferSize), into: previewImage,
                               color: color, blend: paletteBlend)
            engine.encodeUpsample(colorEncoder, from: previewImage, size: gBufferSize, into: accumulator,
                                  outputSize: outputSize)
        }
        renderedColorVersion = colorVersion
    }

    /// The full-resolution image is complete: anti-aliasing samples follow, if any.
    private func startSmoothing() {
        stage = samplesPerPixel > 1 ? .smoothing : .done
        nextSample = 1
        nextTile = 0
    }

    /// Copies the preview's G-buffer for the autopilot (read back once `commandBuffer` completes).
    private func encodeProbeCopy(into commandBuffer: MTLCommandBuffer) -> (width: Int, height: Int, view: Viewport)? {
        guard let view = passView else { return nil }
        let isPreview = previewSize.x > 0
        let (width, height) = isPreview ? (previewSize.x, previewSize.y) : (size.x, size.y)
        let bytes = width * height * 16
        if (probeBuffer?.length ?? 0) < bytes {
            probeBuffer = gpu.device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let source = isPreview ? previewGBuffer : fullGBuffer, let probeBuffer,
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceOffset: 0, to: probeBuffer, destinationOffset: 0, size: bytes)
        blit.endEncoding()
        probeRequested = false
        return (width, height, view)
    }

    private func resize(_ newSize: SIMD2<Int>) {
        if recorder != nil { onRecordingInterrupted?() }
        size = newSize
        surfaceGeneration += 1
        let samples = newSize.x * newSize.y
        previewGBuffer = engine.makeGBuffer(samples: samples)
        fullGBuffer = engine.makeGBuffer(samples: samples)
        jitteredGBuffer = engine.makeGBuffer(samples: samples)
        accumulator = engine.makeAccumulator(width: newSize.x, height: newSize.y)
        finished = (0..<2).map { _ in engine.makeAccumulator(width: newSize.x, height: newSize.y) }
        front = 0
        frontView = nil
        previewImage = engine.makeColorTexture(width: newSize.x, height: newSize.y)
        stage = .preparing
        needsPreview = true
        tiles = LiveRenderer.spiralTiles(width: newSize.x, height: newSize.y, tile: tileSize)
        tileDone = gpu.device.makeBuffer(length: max(tiles.count, 1) * 4, options: .storageModeShared)
    }

    private var tileGrid: SIMD2<UInt32> {
        SIMD2(UInt32((size.x + tileSize - 1) / tileSize), UInt32((size.y + tileSize - 1) / tileSize))
    }

    private func tileIndex(_ tile: SIMD2<Int>) -> Int { (tile.y / tileSize) * Int(tileGrid.x) + tile.x / tileSize }

    /// Tile origins ordered from the centre outwards.
    static func spiralTiles(width: Int, height: Int, tile: Int) -> [SIMD2<Int>] {
        var origins: [SIMD2<Int>] = []
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) { origins.append(SIMD2(x, y)) }
        }
        let centre = SIMD2(Double(width), Double(height)) * 0.5
        func distance2(_ origin: SIMD2<Int>) -> Double {
            let d = SIMD2(Double(origin.x + tile / 2), Double(origin.y + tile / 2)) - centre
            return d.x * d.x + d.y * d.y
        }
        return origins.sorted { distance2($0) < distance2($1) }
    }

    // MARK: Presentation

    /// Shows the latest finished image, reprojected to the current camera, when either changed.
    private func present(in view: MTKView, now: Double) {
        guard finished.count == 2, let frontView else { return }
        guard camera.version != presentedCameraVersion || frontVersion != presentedFrontVersion else { return }
        // A hidden window is not drawn, but a recording still receives frames.
        let visible = view.window?.occlusionState.contains(.visible) ?? false
        guard visible || recorder != nil, presentSlots.wait(timeout: .now()) == .success else { return }
        let drawable = visible ? (view.layer as? CAMetalLayer)?.nextDrawable() : nil
        guard drawable != nil || !visible, let commandBuffer = presentQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            presentSlots.signal()
            return
        }
        let reprojection = camera.view.reprojection(from: frontView, width: size.x, height: size.y, flipY: camera.flipY)
        let sourceSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if let drawable {
            let headroom = drawable.texture.pixelFormat == .rgba16Float ? hdrHeadroom : nil
            engine.encodePresent(encoder, from: finished[front], into: drawable.texture, reprojection: reprojection,
                                 sourceSize: sourceSize, background: color.interior, size: sourceSize, hdrHeadroom: headroom)
        }
        let recorder = recorder
        let frame = recorder?.nextFrame()
        if let recorder, let frame, let texture = CVMetalTextureGetTexture(frame.texture) {
            engine.encodePresent(encoder, from: finished[front], into: texture, reprojection: reprojection,
                                 sourceSize: sourceSize, background: color.interior,
                                 size: SIMD2(UInt32(recorder.width), UInt32(recorder.height)))
        }
        encoder.endEncoding()
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.presentSlots.signal()
            if let recorder, let frame { withExtendedLifetime(frame.texture) { recorder.append(frame.buffer, at: now) } }
        }
        commandBuffer.commit()
        // Only camera motion shows the display rate; at rest presents follow refinement passes.
        if drawable != nil, camera.version != presentedCameraVersion {
            presentTimes.append(now)
            gpu.noteInteraction()
        }
        presentedCameraVersion = camera.version
        presentedFrontVersion = frontVersion
        if recordFrames { logFrame(now: now) }
    }

    /// Renders what is currently on screen into an image (snapshots, Copy Image).
    func captureCanvas() -> CGImage? {
        guard finished.count == 2, let frontView, size.x > 0, size.y > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size.x, height: size.y,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor),
              let commandBuffer = presentQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        let reprojection = camera.view.reprojection(from: frontView, width: size.x, height: size.y, flipY: camera.flipY)
        engine.encodePresent(encoder, from: finished[front], into: texture, reprojection: reprojection,
                             sourceSize: SIMD2(UInt32(size.x), UInt32(size.y)), background: color.interior)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: size.x * size.y * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y),
                             mipmapLevel: 0)
        }
        return Engine.makeImage(pixels: pixels, width: size.x, height: size.y)
    }

    // MARK: Feedback

    /// Frame cost model: ms = tail + samples * perSample. The tail is the serial latency of the
    /// slowest samples (paid once per pass); large passes reveal the per-sample throughput.
    private func learnCost(ms: Double, samples: Int, total: Int) {
        guard samples > 0 else { return }
        let megasamples = Double(samples) / 1e6
        if samples > total / 3 {
            let cost = max(ms - tailMs, 0.01) / megasamples
            msPerMegasample = costMeasured ? msPerMegasample * 0.5 + cost * 0.5 : cost
            costMeasured = true
        } else {
            // Until a large pass has measured it, small passes bound the per-sample cost from above.
            if !costMeasured { msPerMegasample = min(msPerMegasample, max(ms, 0.01) / megasamples) }
            let tail = max(ms - msPerMegasample * megasamples, 0)
            tailMs = tailMs * 0.7 + tail * 0.3
        }
    }

    /// Largest iteration limit the smallest preview affords, from the latest preview (for the autopilot).
    private(set) var affordableIterations = Int.max

    /// Applies the tuner's proposal, keeping the smallest preview within about one frame budget while
    /// moving and two at rest (at least 12 ms each: on faster displays detail is kept at 60 frames per second):
    /// compute passes that run longer hold up presentation, and a preview's time is bounded below by
    /// its slowest samples, which run to the limit, so it grows with the limit. A smallest preview
    /// over two budgets lowers the limit. While the camera moves, increases are rate-limited:
    /// every pass sees a different view, and unthrottled doubling would multiply the cost of each
    /// next preview.
    private func tuneIterations(stats: FSStats, samples: Int, ms: Double, smallest: Bool) {
        guard iter.autoIterations else { return }
        let smallestSamples = Double(size.x * size.y) * LiveRenderer.smallestPreview * LiveRenderer.smallestPreview
        let smallestMs = smallest ? ms : min(ms, tailMs + ms * smallestSamples / Double(max(samples, 1)))
        let frameMs = max(frameBudgetMs, 12)
        let affordable = Double(iter.maxIter) * frameMs / max(smallestMs, 0.1)
        affordableIterations = Int(min(affordable, Double(IterationTuner.ceiling)))
        let moving = camera.isAnimating
        var next = IterationTuner.adjust(maxIter: iter.maxIter, stats: stats, samples: samples)
        var overBudget = false
        if smallest && ms > 2 * frameMs {
            next = min(next, iter.maxIter, max(IterationTuner.floor, Int(max(Double(iter.maxIter) / 16, affordable))))
            overBudget = next < iter.maxIter
        } else if next > iter.maxIter, Double(next) > affordable * (moving ? 1 : 2) {
            // At rest the limit may rise up to what motion tolerates without a cut.
            next = iter.maxIter
        }
        let now = CACurrentMediaTime()
        // Passes encoded before a change are ignored (scene version), so an over-budget cut needs no delay.
        let wait = overBudget ? 0 : next > iter.maxIter ? (moving ? 0.4 : 0.0) : 1.5
        if next != iter.maxIter && now - lastIterationChange > wait {
            lastIterationChange = now
            onIterationProposal?(next)
        }
    }

    private func reportStatus(now: Double) {
        // frame rate over the last second of camera motion; holds the last value at rest
        presentTimes = presentTimes.filter { now - $0 < 1 }
        if presentTimes.count > 1, let first = presentTimes.first, let last = presentTimes.last, last - first > 0.2,
           now - last < 0.05 {
            shownFps = Double(presentTimes.count - 1) / (last - first)
        }
        guard now - lastStatusTime > 0.1, let onStatus else { return }
        lastStatusTime = now
        let reference = engine.references.status
        let progress = switch stage {
        case .refining: Double(nextTile) / Double(max(tiles.count, 1))
        case .smoothing: Double(nextSample) / Double(max(samplesPerPixel, 1))
        case .preparing, .done: 1.0
        }
        onStatus(Status(fps: shownFps, gpuMs: lastGpuMs, stage: stage, progress: progress,
                        maxIter: iter.maxIter, view: camera.view, perturbed: lastPlanPerturbed,
                        referenceProgress: reference.computing ? reference.progress : nil, samples: accumulatedSamples,
                        iterationRate: iterationRate))
    }

    // MARK: Diagnostics (DevHooks)

    var recordFrames = false
    /// Presented frames: time, GPU ms of the last pass, preview scale, zoom, and where the previous
    /// frame's centre went on screen.
    private(set) var frameLog: [(t: Double, gpuMs: Double, scale: Double, log2Radius: Double, pan: SIMD2<Double>)] = []
    /// Draw calls whose CPU time exceeded 12 ms, with the kind of work submitted.
    private(set) var slowFrames: [(t: Double, cpuMs: Double, note: String)] = []
    /// Compute passes: submit time, GPU ms of the iteration, samples, description.
    private(set) var passLog: [(t: Double, ms: Double, samples: Int, note: String)] = []
    private var lastWorkNote = ""
    private var loggedView: Viewport?

    func resetFrameLog() {
        frameLog.removeAll()
        loggedView = nil
        slowFrames.removeAll()
        passLog.removeAll()
    }

    private func logFrame(now: Double) {
        let pan = loggedView.map {
            camera.view.pixel(of: $0.center, width: size.x, height: size.y, flipY: camera.flipY)
                - SIMD2(Double(size.x), Double(size.y)) * 0.5
        } ?? .zero
        frameLog.append((now, lastGpuMs, previewScale, camera.view.log2Radius, pan))
        loggedView = camera.view
    }
}
