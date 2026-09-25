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

    // Inputs (main thread)
    var formula = Formula() { didSet { if formula != oldValue { sceneVersion += 1 } } }
    var iter = IterationSettings() { didSet { if iter != oldValue { sceneVersion += 1 } } }
    var color = ColorSettings() { didSet { if color != oldValue { colorVersion += 1 } } }
    var aaSamples = 16 { didSet { if aaSamples != oldValue { colorVersion += 1 } } }
    var budgetMs = 7.0
    var paletteBlend: Engine.PaletteBlend?
    /// EDR headroom when HDR output is on (nil: standard range).
    var hdrHeadroom: Float? { didSet { if hdrHeadroom != oldValue { presentedFrontVersion = -1 } } }
    private(set) var sceneVersion = 0
    private(set) var colorVersion = 0
    /// Set when the next preview should snap colour statistics instead of easing them.
    var snapColors = true

    /// Reported to the HUD roughly ten times a second.
    var onStatus: ((Status) -> Void)?
    /// Auto-iteration proposals (main thread).
    var onIterationProposal: ((Int) -> Void)?
    /// Called at the start of every display frame with the elapsed time.
    var onFrame: ((Double) -> Void)?

    /// Coarse copy of the latest preview's escape iterations, for steering the autopilot.
    struct Probe {
        var width: Int
        var height: Int
        var view: Viewport
        var drawable: SIMD2<Int>
        var iterations: [UInt32]
    }
    /// Set to receive the next preview's iterations via `onProbe` (main thread).
    var probeRequested = false
    var onProbe: ((Probe) -> Void)?
    private var probeBuffer: MTLBuffer?

    /// Current drawable size in pixels, for converting pointer positions.
    var drawableSizeForPicking: SIMD2<Int> { size.x > 0 ? size : SIMD2(1, 1) }

    struct Status {
        var fps: Double
        var gpuMs: Double
        var stage: String
        var progress: Double
        var maxIter: Int
        var view: Viewport
        var perturbed: Bool
        var referenceProgress: Double?
        var samples: Int
        /// Effective iterations per second of GPU time over the last compute passes.
        var iterationRate: Double
    }

    // Surfaces
    private var size = SIMD2<Int>(0, 0)
    private var gPreview: MTLBuffer?
    private var gFull: MTLBuffer?
    private var gAA: MTLBuffer?
    private var previewColor: MTLTexture?
    /// Working image of the compute passes (sums anti-aliasing samples).
    private var accum: MTLTexture?
    /// Finished images: `display[front]` is shown, the other receives the next pass.
    private var display: [MTLTexture] = []
    private var front = 0
    private var frontView: Viewport?
    private var frontVersion = 0
    private var presentedFrontVersion = -1
    private var presentedCameraVersion = -1
    private var previewSize = SIMD2<Int>(0, 0)

    // Progressive state (compute side)
    private enum Stage: Equatable {
        case idle, full, aa, done
    }
    private var stage = Stage.idle
    private var targetView: Viewport?
    private var tiles: [SIMD2<Int>] = []
    private var nextTile = 0
    private let tileSize = 128
    private var tileDone: MTLBuffer?
    private var aaIndex = 0
    private var accSamples = 0
    private var needsPreview = true
    private var renderedScene = -1
    private var renderedCameraVersion = -1
    private var renderedColor = -1
    private var lastPlanPerturbed = false
    private var lastPreviewSlot: UInt32?
    private var statsSettled = true
    private var previewScale = 1.0
    private var computeBusy = false
    /// Incremented when surfaces are reallocated; passes encoded for older surfaces don't publish.
    private var surfaceGeneration = 0

    // Timing
    private var costMsPerMSample = 20.0
    private var tailMs = 1.0
    private var cbIter: MTLCommandBuffer?
    private var tileEncoder: MTLComputeCommandEncoder?
    private var lastTime = CACurrentMediaTime()
    private var frameTimes: [Double] = []
    private var lastStatus = 0.0
    private var lastGpuMs = 0.0
    private var lastIterChange = 0.0
    private var iterationRate = 0.0
    private let presentInFlight = DispatchSemaphore(value: 2)

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

    func invalidate() { needsPreview = true }

    func resetFrameLog() {
        frameLog.removeAll()
        slowFrames.removeAll()
        passLog.removeAll()
    }

    /// Forces a recolour with the current settings (e.g. after a palette cross-fade ends).
    func recolor() { colorVersion += 1 }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        defer {
            let cpu = (CACurrentMediaTime() - now) * 1000
            if recordFrames && cpu > 12 { slowFrames.append((now, cpu, lastWorkNote)) }
        }
        let dt = min(now - lastTime, 0.05)
        lastTime = now
        onFrame?(dt)
        (view as? FractalMTKView)?.syncOutputFormat()
        let ds = view.drawableSize
        let sz = SIMD2(Int(ds.width), Int(ds.height))
        guard sz.x > 0, sz.y > 0 else { return }
        if sz != size { resize(sz) }

        camera.flipY = formula.family.flipY
        _ = camera.update(dt: dt, width: sz.x, height: sz.y)
        if !computeBusy { submitCompute() }
        present(in: view, now: now)
        reportStatus(now: now)
    }

    /// Encodes and commits the next compute pass, if there is work to do.
    private func submitCompute() {
        let moved = camera.version != renderedCameraVersion
        let sceneChanged = sceneVersion != renderedScene
        let colorChanged = colorVersion != renderedColor || paletteBlend != nil
        enum Work { case preview, refine, recolor }
        let work: Work
        if moved || sceneChanged || needsPreview {
            work = .preview
        } else if colorChanged {
            work = .recolor
        } else if stage == .full || stage == .aa {
            work = .refine
        } else {
            return
        }
        lastWorkNote = "\(work)"
        guard let cbIter = gpu.queue.makeCommandBuffer(), let encIter = cbIter.makeComputeCommandEncoder(),
              let cbColor = gpu.queue.makeCommandBuffer(), let encColor = cbColor.makeComputeCommandEncoder() else { return }
        self.cbIter = cbIter
        var iteratedSamples = 0
        var statsSlot: UInt32?
        let sceneAtEncode = sceneVersion
        var produced = true

        switch work {
        case .preview:
            let r = encodePreview(iter: encIter, color: encColor, view: camera.view, moving: moved || camera.isAnimating)
            iteratedSamples = r.samples
            statsSlot = r.slot
            produced = r.samples > 0
        case .recolor:
            encodeRecolor(enc: encColor)
        case .refine:
            iteratedSamples = encodeRefine(iter: encIter, color: encColor)
            produced = iteratedSamples > 0 || stage == .done
        }
        if let e = tileEncoder {
            e.endEncoding()
            tileEncoder = nil
        } else {
            encIter.endEncoding()
        }
        self.cbIter = nil
        encColor.endEncoding()

        // Hand a copy of the preview's iterations to the autopilot when asked.
        var probeInfo: (Int, Int, Viewport)?
        if work == .preview, produced, probeRequested, let v = targetView, previewSize.x > 0 || stage != .full {
            let pw = previewSize.x > 0 ? previewSize.x : size.x, ph = previewSize.x > 0 ? previewSize.y : size.y
            let src = previewSize.x > 0 ? gPreview : gFull
            let bytes = pw * ph * 16
            if probeBuffer == nil || probeBuffer!.length < bytes {
                probeBuffer = gpu.device.makeBuffer(length: bytes, options: .storageModeShared)
            }
            if let src, let dst = probeBuffer, let blit = cbColor.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes)
                blit.endEncoding()
                probeInfo = (pw, ph, v)
                probeRequested = false
            }
        }

        // Publish the working image into the back display buffer.
        let back = 1 - front
        let publishedView = targetView
        if produced, let accum, display.count == 2, let blit = cbColor.makeBlitCommandEncoder() {
            blit.copy(from: accum, to: display[back])
            blit.endEncoding()
        }

        let samples = iteratedSamples
        let totalSamples = size.x * size.y
        let submitTime = CACurrentMediaTime()
        let note = "\(work) scale \(String(format: "%.2f", previewScale)) iter \(iter.maxIter)"
        cbIter.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                if self.recordFrames { self.passLog.append((submitTime, ms, samples, note)) }
                self.lastGpuMs = ms
                self.learnCost(ms: ms, samples: samples, total: totalSamples)
                if let slot = statsSlot {
                    let st = self.engine.readStats(slot)
                    if ms > 0.5 { self.iterationRate = self.iterationRate * 0.7 + Double(st.iterations) / (ms / 1000) * 0.3 }
                    if sceneAtEncode == self.sceneVersion { self.consider(stats: st, samples: samples) }
                }
            }
        }
        let drawable = size
        let generation = surfaceGeneration
        cbColor.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let (pw, ph, v) = probeInfo, let buf = self.probeBuffer, generation == self.surfaceGeneration {
                    let raw = buf.contents().assumingMemoryBound(to: UInt32.self)
                    let its = (0..<(pw * ph)).map { raw[$0 * 4] }
                    self.onProbe?(Probe(width: pw, height: ph, view: v, drawable: drawable, iterations: its))
                }
                self.computeBusy = false
                if produced && self.display.count == 2 && generation == self.surfaceGeneration {
                    self.front = back
                    self.frontView = publishedView
                    self.frontVersion += 1
                }
            }
        }
        computeBusy = true
        cbIter.commit()
        cbColor.commit()
    }

    /// Shows the latest finished image, reprojected to the current camera, when either changed.
    private func present(in view: MTKView, now: Double) {
        guard display.count == 2, let fv = frontView else { return }
        guard camera.version != presentedCameraVersion || frontVersion != presentedFrontVersion else { return }
        let visible = view.window?.occlusionState.contains(.visible) ?? false
        guard visible, presentInFlight.wait(timeout: .now()) == .success else { return }
        guard let layer = view.layer as? CAMetalLayer, let drawable = layer.nextDrawable(),
              let cb = presentQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            presentInFlight.signal()
            return
        }
        let rep = camera.view.reprojection(from: fv, width: size.x, height: size.y, flipY: camera.flipY)
        let sz = SIMD2(UInt32(size.x), UInt32(size.y))
        let hdr = drawable.texture.pixelFormat == .rgba16Float ? hdrHeadroom : nil
        engine.encodePresent(enc, acc: display[front], dst: drawable.texture, reprojection: rep, srcSize: sz,
                             background: color.interior, size: sz, hdrHeadroom: hdr)
        enc.endEncoding()
        cb.present(drawable)
        cb.addCompletedHandler { [weak self] _ in self?.presentInFlight.signal() }
        cb.commit()
        presentedCameraVersion = camera.version
        presentedFrontVersion = frontVersion
        frameTimes.append(now)
        if recordFrames { frameLog.append((now, lastGpuMs, previewScale)) }
    }

    /// Renders what is currently on screen into an image (snapshots).
    func captureCanvas() -> CGImage? {
        guard display.count == 2, let fv = frontView, size.x > 0, size.y > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size.x, height: size.y, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .shared
        guard let tex = gpu.device.makeTexture(descriptor: d),
              let cb = presentQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        let rep = camera.view.reprojection(from: fv, width: size.x, height: size.y, flipY: camera.flipY)
        engine.encodePresent(enc, acc: display[front], dst: tex, reprojection: rep,
                             srcSize: SIMD2(UInt32(size.x), UInt32(size.y)), background: color.interior)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: size.x * size.y * 4)
        px.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// True when the view is fully refined (for scripted snapshots).
    var isSettled: Bool { stage == .done && !camera.isAnimating && !needsPreview && !computeBusy }

    // MARK: Passes

    private func resize(_ sz: SIMD2<Int>) {
        size = sz
        surfaceGeneration += 1
        let n = sz.x * sz.y
        gPreview = engine.makeGBuffer(samples: n)
        gFull = engine.makeGBuffer(samples: n)
        gAA = engine.makeGBuffer(samples: n)
        accum = engine.makeAccumulator(width: sz.x, height: sz.y)
        display = [engine.makeAccumulator(width: sz.x, height: sz.y), engine.makeAccumulator(width: sz.x, height: sz.y)]
        front = 0
        frontView = nil
        previewColor = engine.makeColorTexture(width: sz.x, height: sz.y)
        stage = .idle
        needsPreview = true
        tiles = LiveRenderer.spiralTiles(width: sz.x, height: sz.y, tile: tileSize)
        tileDone = gpu.device.makeBuffer(length: max(tiles.count, 1) * 4, options: .storageModeShared)
    }

    private func scene(_ v: Viewport) -> FractalScene { FractalScene(formula: formula, view: v, iter: iter) }

    /// Renders the whole view at a resolution that fits the frame budget.
    private func encodePreview(iter: MTLComputeCommandEncoder, color enc: MTLComputeCommandEncoder, view v: Viewport,
                               moving: Bool) -> (samples: Int, slot: UInt32?) {
        let full = Double(size.x * size.y)
        let affordable = max(budgetMs - tailMs, 0.5) / max(costMsPerMSample, 1e-6) * 1e6   // samples
        var s = sqrt(affordable / full)
        s = min(1, max(0.12, s))
        if abs(s - previewScale) / previewScale > 0.12 || s == 1 { previewScale = s }
        if !moving && previewScale > 0.7 { previewScale = 1 }
        let pw = max(8, Int(Double(size.x) * previewScale)), ph = max(8, Int(Double(size.y) * previewScale))

        let slot = engine.nextStatsSlot()
        guard let plan = engine.makePlan(scene: scene(v), grid: Engine.Grid(width: pw, height: ph), enc: iter,
                                         blocking: false, focus: camera.focus(width: size.x, height: size.y),
                                         statsSlot: slot, exclusive: true),
              let gPreview, let gFull, let accum, let previewColor else {
            needsPreview = true   // reference still computing: keep reprojecting the last image
            return (0, nil)
        }
        needsPreview = false
        renderedCameraVersion = camera.version
        lastPlanPerturbed = plan.perturbed
        let full1 = pw == size.x && ph == size.y
        let target = full1 ? gFull : gPreview
        let gs = SIMD2(UInt32(pw), UInt32(ph))
        engine.encodeStatsReset(iter, slot: slot)
        engine.encodeIterate(iter, plan: plan, gbuf: target, origin: .zero, size: gs, bufOrigin: .zero, bufStride: UInt32(pw))
        // Ease colour statistics while moving (temporal stability); snap at rest or after jumps.
        engine.encodeStatsSmooth(iter, slot: slot, alpha: snapColors || !moving ? 1 : 0.2)
        snapColors = false
        lastPreviewSlot = slot
        statsSettled = !moving
        let outSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if full1 {
            engine.encodeColorize(enc, acc: accum, primary: .init(buffer: gFull, size: outSize), fallback: nil,
                                  color: color, blend: paletteBlend, accumulate: false, outSize: outSize)
        } else {
            engine.encodeShade(enc, source: .init(buffer: gPreview, size: gs), dst: previewColor, color: color, blend: paletteBlend)
            engine.encodeUpsample(enc, src: previewColor, size: gs, acc: accum, outSize: outSize)
        }
        accSamples = 1
        previewSize = SIMD2(pw, ph)
        targetView = v
        renderedScene = sceneVersion
        renderedColor = colorVersion
        if full1 {
            previewSize = .zero
            stage = aaSamples > 1 ? .aa : .done
            aaIndex = 1
            nextTile = 0
        } else {
            stage = .full
            nextTile = 0
            memset(tileDone!.contents(), 0, tileDone!.length)
        }
        return (pw * ph, slot)
    }

    /// Continues the full-resolution pass or the next anti-aliasing sample within the frame budget.
    private func encodeRefine(iter: MTLComputeCommandEncoder, color enc: MTLComputeCommandEncoder) -> Int {
        guard let v = targetView, let accum, let gFull, let gAA, let previewColor else { return 0 }
        let jitter = stage == .aa ? Engine.jitter(aaIndex) : .zero
        let slot = engine.nextStatsSlot()
        guard let plan = engine.makePlan(scene: scene(v), grid: Engine.Grid(width: size.x, height: size.y, jitter: jitter),
                                         enc: iter, blocking: false, statsSlot: slot, exclusive: true) else { return 0 }
        let target = stage == .aa ? gAA : gFull
        if !statsSettled, let slot = lastPreviewSlot {
            // motion ended: settle colours on the last preview's statistics
            engine.encodeStatsSmooth(iter, slot: slot, alpha: 1)
            statsSettled = true
        }
        // Tiles write disjoint regions, so they run concurrently and share the slow-pixel tail.
        iter.endEncoding()
        guard let conc = cbIter?.makeComputeCommandEncoder(dispatchType: .concurrent) else { return 0 }
        tileEncoder = conc
        let tileSamples = Double(tileSize * tileSize)
        var count = max(1, Int(max(budgetMs - tailMs, 0.5) / max(costMsPerMSample * tileSamples / 1e6, 1e-4)))
        var samples = 0
        let done = tileDone!.contents().assumingMemoryBound(to: UInt32.self)
        while count > 0 && nextTile < tiles.count {
            let t = tiles[nextTile]
            let w = min(tileSize, size.x - t.x), h = min(tileSize, size.y - t.y)
            engine.encodeIterate(conc, plan: plan, gbuf: target, origin: SIMD2(UInt32(t.x), UInt32(t.y)),
                                 size: SIMD2(UInt32(w), UInt32(h)), bufOrigin: .zero, bufStride: UInt32(size.x))
            if stage == .full { done[tileIndex(t)] = 1 }
            samples += w * h
            nextTile += 1
            count -= 1
        }
        let outSize = SIMD2(UInt32(size.x), UInt32(size.y))
        if stage == .full {
            let complete = nextTile >= tiles.count
            let fb = Engine.TileFallback(preview: previewColor, previewSize: SIMD2(UInt32(previewSize.x), UInt32(previewSize.y)),
                                         done: tileDone!, grid: tileGrid, tileSize: UInt32(tileSize))
            engine.encodeColorize(enc, acc: accum, primary: .init(buffer: gFull, size: outSize),
                                  fallback: complete ? nil : fb, color: color, blend: paletteBlend,
                                  accumulate: false, outSize: outSize)
            accSamples = 1
            if complete {
                stage = aaSamples > 1 ? .aa : .done
                aaIndex = 1
                nextTile = 0
            }
        } else if nextTile >= tiles.count {
            engine.encodeColorize(enc, acc: accum, primary: .init(buffer: gAA, size: outSize), fallback: nil,
                                  color: color, blend: paletteBlend, accumulate: true, outSize: outSize)
            accSamples += 1
            aaIndex += 1
            nextTile = 0
            if aaIndex >= aaSamples { stage = .done }
        }
        return samples
    }

    /// Recolours the best finished G-buffer after a palette or shading change; anti-aliasing restarts.
    private func encodeRecolor(enc: MTLComputeCommandEncoder) {
        guard let accum else { return }
        let outSize = SIMD2(UInt32(size.x), UInt32(size.y))
        let fullDone = stage == .aa || stage == .done
        if fullDone, let gFull {
            engine.encodeColorize(enc, acc: accum, primary: .init(buffer: gFull, size: outSize), fallback: nil,
                                  color: color, blend: paletteBlend, accumulate: false, outSize: outSize)
            accSamples = 1
            if aaSamples > 1 {
                stage = .aa
                aaIndex = 1
                nextTile = 0
            }
        } else if let gPreview, let previewColor, previewSize.x > 0 {
            let gs = SIMD2(UInt32(previewSize.x), UInt32(previewSize.y))
            engine.encodeShade(enc, source: .init(buffer: gPreview, size: gs), dst: previewColor, color: color, blend: paletteBlend)
            engine.encodeUpsample(enc, src: previewColor, size: gs, acc: accum, outSize: outSize)
        }
        renderedColor = colorVersion
    }

    private var tileGrid: SIMD2<UInt32> {
        SIMD2(UInt32((size.x + tileSize - 1) / tileSize), UInt32((size.y + tileSize - 1) / tileSize))
    }

    private func tileIndex(_ t: SIMD2<Int>) -> Int { (t.y / tileSize) * Int(tileGrid.x) + t.x / tileSize }

    /// Tile origins ordered from the centre outwards.
    static func spiralTiles(width: Int, height: Int, tile: Int) -> [SIMD2<Int>] {
        var out: [SIMD2<Int>] = []
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) { out.append(SIMD2(x, y)) }
        }
        let c = SIMD2(Double(width), Double(height)) * 0.5
        return out.sorted {
            let a = SIMD2(Double($0.x + tile / 2), Double($0.y + tile / 2)) - c
            let b = SIMD2(Double($1.x + tile / 2), Double($1.y + tile / 2)) - c
            return a.x * a.x + a.y * a.y < b.x * b.x + b.y * b.y
        }
    }

    // MARK: Feedback

    /// Frame cost model: ms = tail + samples * perSample. The tail is the serial latency of the
    /// slowest samples (paid once per pass); large passes reveal the per-sample throughput.
    private func learnCost(ms: Double, samples: Int, total: Int) {
        guard samples > 0 else { return }
        let n = Double(samples) / 1e6
        if samples > total / 3 {
            let c = max(ms - tailMs, 0.01) / n
            costMsPerMSample = costMsPerMSample * 0.5 + c * 0.5
        } else {
            let tail = max(ms - costMsPerMSample * n, 0)
            tailMs = tailMs * 0.7 + tail * 0.3
        }
    }

    /// Applies the tuner's proposal. While the camera moves, increases are rate-limited: every pass
    /// sees a different view, and unthrottled doubling would multiply the cost of each next preview.
    private func consider(stats: FSStats, samples: Int) {
        guard iter.autoIterations else { return }
        var next = IterationTuner.adjust(maxIter: iter.maxIter, stats: stats, samples: samples)
        // Keep the view interactive: no automatic increase once a full frame would take ~0.6 s.
        let fullFrameMs = tailMs + costMsPerMSample * Double(size.x * size.y) / 1e6
        if next > iter.maxIter && fullFrameMs > 600 { next = iter.maxIter }
        let now = CACurrentMediaTime()
        let moving = camera.isAnimating
        let wait = next > iter.maxIter ? (moving ? 0.4 : 0.0) : 1.5
        if next != iter.maxIter && now - lastIterChange > wait {
            lastIterChange = now
            onIterationProposal?(next)
        }
    }

    /// Frame rate over the last second of presenting; holds the last value while idle.
    private var shownFps = 0.0
    private(set) var frameLog: [(t: Double, gpuMs: Double, scale: Double)] = []
    /// Draw calls whose CPU time exceeded 12 ms, with the kind of work submitted.
    private(set) var slowFrames: [(t: Double, cpuMs: Double, note: String)] = []
    /// Compute passes: submit time, GPU ms of the iteration, samples, description.
    private(set) var passLog: [(t: Double, ms: Double, samples: Int, note: String)] = []
    private var lastWorkNote = ""
    var recordFrames = false

    private func reportStatus(now: Double) {
        frameTimes = frameTimes.filter { now - $0 < 1 }
        if frameTimes.count > 1, let first = frameTimes.first, let last = frameTimes.last, last - first > 0.2,
           now - last < 0.05 {
            shownFps = Double(frameTimes.count - 1) / (last - first)
        }
        guard now - lastStatus > 0.1, let onStatus else { return }
        lastStatus = now
        let ref = engine.references.status
        let progress: Double
        switch stage {
        case .full: progress = Double(nextTile) / Double(max(tiles.count, 1))
        case .aa: progress = Double(aaIndex) / Double(max(aaSamples, 1))
        default: progress = 1
        }
        let stageName: String
        switch stage {
        case .idle: stageName = "Preparing"
        case .full: stageName = "Refining"
        case .aa: stageName = "Smoothing"
        case .done: stageName = "Done"
        }
        onStatus(Status(fps: shownFps, gpuMs: lastGpuMs, stage: stageName, progress: progress,
                        maxIter: iter.maxIter, view: camera.view, perturbed: lastPlanPerturbed,
                        referenceProgress: ref.computing ? ref.progress : nil, samples: accSamples,
                        iterationRate: iterationRate))
    }
}
