import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CFractal

/// Turns scenes into G-buffers (iteration data) and colours; shared by the interactive view and exports.
public final class Engine: @unchecked Sendable {
    public let gpu = GPU.shared
    public let palettes: PaletteBank
    public let references = ReferenceStore()
    let stats: MTLBuffer
    /// Smoothed colour-normalisation statistics (float4: low iteration, span, -, valid).
    public let smooth: MTLBuffer
    private let dummy: MTLBuffer
    private var slot: UInt32 = 0

    public init() {
        let device = gpu.device
        palettes = PaletteBank(device: device)
        stats = device.makeBuffer(length: 256 * MemoryLayout<FSStats>.stride, options: .storageModeShared)!
        smooth = device.makeBuffer(length: 16, options: .storageModeShared)!
        memset(smooth.contents(), 0, 16)
        dummy = device.makeBuffer(length: 256, options: .storageModePrivate)!
    }

    public func nextStatsSlot() -> UInt32 {
        slot = (slot + 1) % 256
        return slot
    }

    public func readStats(_ slot: UInt32) -> FSStats {
        stats.contents().assumingMemoryBound(to: FSStats.self)[Int(slot)]
    }

    /// Sample grid of one pass: full size in samples plus a sub-sample jitter.
    public struct Grid: Sendable {
        public var width: Int
        public var height: Int
        public var jitter = SIMD2<Float>(0, 0)

        public init(width: Int, height: Int, jitter: SIMD2<Float> = .zero) {
            self.width = width
            self.height = height
            self.jitter = jitter
        }
    }

    /// Everything the iteration kernel needs for one pass.
    public struct Plan {
        var params: FSIterParams
        var pipeline: MTLComputePipelineState
        var ref: ReferenceOrbit.Snapshot?
        var bla: BLATable?
        public var perturbed: Bool
        public var deep: Bool
        public var effectiveMaxIter: Int
        public var usedBLA: Bool { bla != nil }
    }

    /// Prepares a pass; returns nil while a needed reference orbit is still being computed.
    /// Encodes BLA table construction into `cb` when the table must be (re)built.
    public func makePlan(scene: Scene, grid: Grid, cb: MTLCommandBuffer, blocking: Bool,
                         focus: PlanePoint? = nil, statsSlot: UInt32) -> Plan? {
        let f = scene.formula
        let v = scene.view
        let minSide = Double(min(grid.width, grid.height))
        let log2Step = v.log2Radius + 1 - log2(minSide)
        let step = FloatExp.fromLog2(log2Step)
        let cs = cos(v.rotation), sn = sin(v.rotation)
        let fy: Double = f.family.flipY ? -1 : 1

        var p = FSIterParams()
        p.size = SIMD2(UInt32(grid.width), UInt32(grid.height))
        p.bufStride = UInt32(grid.width)
        p.stepX = SIMD2(Float(step.m * cs), Float(step.m * sn))
        p.stepY = SIMD2(Float(step.m * sn * fy), Float(-step.m * cs * fy))
        p.stepE = Int32(step.e)
        p.jitter = grid.jitter
        p.juliaC = SIMD2(Float(f.juliaRe), Float(f.juliaIm))
        p.bailout2 = Float(scene.iter.bailout * scene.iter.bailout)
        p.log2Bailout2 = log2(p.bailout2)
        p.invLog2Power = 1 / log2(Float(f.effectivePower))
        p.log2Step = Float(log2Step)
        p.statsSlot = statsSlot
        let maxIter = max(scene.iter.maxIter, 16)
        p.maxIter = UInt32(maxIter)

        var key = GPU.PipelineKey(name: "iterate_direct")
        key.formula = f.family.formulaID
        key.power = Int32(f.effectivePower)
        key.julia = f.julia
        key.withDer = scene.iter.derivative

        let perturb = !f.julia && log2Step < -18
        if !perturb {
            p.offsetM = SIMD2(Float(v.center.re.doubleValue), Float(v.center.im.doubleValue))
            return Plan(params: p, pipeline: gpu.pipeline(key), ref: nil, bla: nil, perturbed: false, deep: false,
                        effectiveMaxIter: maxIter)
        }

        guard let ref = references.reference(formula: f, view: v, minSide: minSide, length: maxIter + 1,
                                             focus: focus, blocking: blocking) else { return nil }
        let snap = ref.snapshot
        guard snap.count >= 2 else { return nil }
        let offset = v.center.minus(ref.center)
        let sh = offset.shared
        p.offsetM = sh.m
        p.offsetE = sh.e
        let effMax = snap.escaped ? maxIter : min(maxIter, snap.count - 1)
        p.maxIter = UInt32(effMax)
        p.refLen = UInt32(snap.count)

        // Largest |dc| over the grid decides how far each approximation may reach.
        let halfDiag = log2Step + log2(0.5 * hypot(Double(grid.width), Double(grid.height)))
        let lo = offset.log2Abs
        let log2C = lo.isFinite ? max(lo, halfDiag) + log2(1 + exp2(-abs(lo - halfDiag))) : halfDiag
        let eps = scene.iter.blaLog2Eps
        var table = scene.iter.useBLA ? ref.bla : nil
        if !scene.iter.useBLA {
        } else if table == nil || table!.refCount != snap.count || table!.log2Eps != eps
            || log2C > table!.log2C || log2C < table!.log2C - 4 {
            table = BLATable(encodingInto: cb, snapshot: snap, formula: f, log2C: log2C + 1, log2Eps: eps)
            ref.bla = table
        }
        if let t = table {
            p.blaLevels = UInt32(t.offsets.count)
            withUnsafeMutableBytes(of: &p.blaOffset) { raw in
                let b = raw.bindMemory(to: UInt32.self)
                for (i, o) in t.offsets.enumerated() { b[i] = o }
            }
            withUnsafeMutableBytes(of: &p.blaCount) { raw in
                let b = raw.bindMemory(to: UInt32.self)
                for (i, c) in t.counts.enumerated() { b[i] = c }
            }
        }
        let deep = log2Step < -50
        key.name = "iterate_perturb"
        key.useBLA = table != nil
        key.deep = deep
        return Plan(params: p, pipeline: gpu.pipeline(key), ref: snap, bla: table, perturbed: true, deep: deep,
                    effectiveMaxIter: effMax)
    }

    /// Iterates the samples of `origin ..< origin + size` into `gbuf` laid out from `bufOrigin` with `bufStride`.
    public func encodeIterate(_ enc: MTLComputeCommandEncoder, plan: Plan, gbuf: MTLBuffer,
                              origin: SIMD2<UInt32>, size: SIMD2<UInt32>,
                              bufOrigin: SIMD2<UInt32>, bufStride: UInt32) {
        var p = plan.params
        p.origin = origin
        p.bufOrigin = bufOrigin
        p.bufStride = bufStride
        enc.setBuffer(gbuf, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<FSIterParams>.stride, index: 1)
        if let r = plan.ref {
            enc.setBuffer(r.zf, offset: 0, index: 2)
            enc.setBuffer(r.zx, offset: 0, index: 3)
            enc.setBuffer(plan.bla?.entries ?? dummy, offset: 0, index: 4)
            enc.setBuffer(plan.bla?.r2 ?? dummy, offset: 0, index: 5)
            enc.setBuffer(plan.bla?.logR ?? dummy, offset: 0, index: 6)
        }
        enc.setBuffer(stats, offset: 0, index: 7)
        gpu.dispatch2D(enc, plan.pipeline, width: Int(size.x), height: Int(size.y))
    }

    public func encodeStatsReset(_ enc: MTLComputeCommandEncoder, slot: UInt32) {
        var s = slot
        enc.setBuffer(stats, offset: 0, index: 7)
        enc.setBytes(&s, length: 4, index: 0)
        gpu.dispatch1D(enc, gpu.pipeline("stats_reset"), count: 1)
    }

    /// Folds a finished pass's statistics into the colour normalisation; alpha 1 snaps.
    public func encodeStatsSmooth(_ enc: MTLComputeCommandEncoder, slot: UInt32, alpha: Float) {
        var args = SIMD2<Float>(Float(slot), alpha)
        enc.setBuffer(stats, offset: 0, index: 7)
        enc.setBuffer(smooth, offset: 0, index: 0)
        enc.setBytes(&args, length: 8, index: 1)
        gpu.dispatch1D(enc, gpu.pipeline("stats_smooth"), count: 1)
    }

    public func resetSmoothing() {
        memset(smooth.contents(), 0, 16)
    }

    /// Source G-buffer for colouring.
    public struct GSource {
        public var buffer: MTLBuffer
        public var size: SIMD2<UInt32>

        public init(buffer: MTLBuffer, size: SIMD2<UInt32>) {
            self.buffer = buffer
            self.size = size
        }
    }

    /// Partially finished primary pass: tiles not yet done fall back to another G-buffer.
    public struct TileFallback {
        public var source: GSource
        public var done: MTLBuffer
        public var grid: SIMD2<UInt32>
        public var tileSize: UInt32

        public init(source: GSource, done: MTLBuffer, grid: SIMD2<UInt32>, tileSize: UInt32) {
            self.source = source
            self.done = done
            self.grid = grid
            self.tileSize = tileSize
        }
    }

    public struct PaletteBlend: Sendable {
        public var from: Int
        public var to: Int
        public var mix: Float

        public init(from: Int, to: Int, mix: Float) {
            self.from = from
            self.to = to
            self.mix = mix
        }
    }

    public func encodeColorize(_ enc: MTLComputeCommandEncoder, acc: MTLTexture, primary: GSource,
                               fallback: TileFallback?, color: ColorSettings, blend: PaletteBlend? = nil,
                               accumulate: Bool, time: Float = 0, outSize: SIMD2<UInt32>? = nil) {
        var c = FSColorParams()
        c.outSize = outSize ?? SIMD2(UInt32(acc.width), UInt32(acc.height))
        c.gSize = primary.size
        c.density = Float(color.density)
        c.offset = Float(color.offset)
        c.mapping = Int32(color.mapping)
        c.lightAzimuth = Float(color.lightAzimuth)
        c.lightElevation = Float(color.lightElevation)
        c.lightStrength = Float(color.lightStrength)
        c.edgeStrength = Float(color.edgeStrength)
        c.paletteCount = Float(palettes.count)
        if let b = blend {
            c.paletteRow = Float(b.from)
            c.paletteRowB = Float(b.to)
            c.paletteMix = b.mix
        } else {
            c.paletteRow = Float(color.palette)
            c.paletteRowB = Float(color.palette)
            c.paletteMix = 0
        }
        c.interior = SIMD4(color.interior, 1)
        c.accumulate = accumulate ? 1 : 0
        c.time = time
        if let fb = fallback {
            c.useFallback = 1
            c.fbSize = fb.source.size
            c.tileGrid = fb.grid
            c.tileSize = fb.tileSize
        } else {
            c.fbSize = primary.size
            c.tileGrid = SIMD2(1, 1)
            c.tileSize = 1
        }
        enc.setTexture(acc, index: 0)
        enc.setTexture(palettes.texture, index: 1)
        enc.setBuffer(primary.buffer, offset: 0, index: 0)
        enc.setBuffer(fallback?.source.buffer ?? primary.buffer, offset: 0, index: 1)
        enc.setBuffer(fallback?.done ?? dummy, offset: 0, index: 2)
        enc.setBytes(&c, length: MemoryLayout<FSColorParams>.stride, index: 3)
        enc.setBuffer(smooth, offset: 0, index: 4)
        gpu.dispatch2D(enc, gpu.pipeline("colorize"), width: Int(c.outSize.x), height: Int(c.outSize.y))
    }

    public func encodePresent(_ enc: MTLComputeCommandEncoder, acc: MTLTexture, dst: MTLTexture, samples: Int,
                              dither: Float = 1.0 / 255.0, exposure: Float = 1, size: SIMD2<UInt32>? = nil) {
        var p = FSPresentParams()
        p.size = size ?? SIMD2(UInt32(dst.width), UInt32(dst.height))
        p.invCount = 1 / Float(max(samples, 1))
        p.ditherAmp = dither
        p.exposure = exposure
        enc.setTexture(acc, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&p, length: MemoryLayout<FSPresentParams>.stride, index: 0)
        gpu.dispatch2D(enc, gpu.pipeline("present"), width: Int(p.size.x), height: Int(p.size.y))
    }

    public func makeGBuffer(samples: Int) -> MTLBuffer {
        gpu.device.makeBuffer(length: max(samples, 1) * 16, options: .storageModePrivate)!
    }

    public func makeAccumulator(width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return gpu.device.makeTexture(descriptor: d)!
    }

    /// Low-discrepancy sub-pixel offsets (R2 sequence, tent-filtered); sample 0 is the pixel centre.
    public static func jitter(_ i: Int) -> SIMD2<Float> {
        if i == 0 { return .zero }
        let g = 1.32471795724474602596
        let u = (0.5 + Double(i) / g).truncatingRemainder(dividingBy: 1)
        let v = (0.5 + Double(i) / (g * g)).truncatingRemainder(dividingBy: 1)
        func tent(_ x: Double) -> Double { x < 0.5 ? sqrt(2 * x) - 1 : 1 - sqrt(2 - 2 * x) }
        return SIMD2(Float(tent(u) * 0.75), Float(tent(v) * 0.75))
    }
}

// MARK: - Still images

extension Engine {
    public struct StillOptions: Sendable {
        public var width: Int
        public var height: Int
        public var samples: Int
        public var tile = 2048

        public init(width: Int, height: Int, samples: Int, tile: Int = 2048) {
            self.width = width
            self.height = height
            self.samples = samples
            self.tile = tile
        }
    }

    /// Runs a low-resolution pass to set colour statistics and, if enabled, the iteration limit.
    public func calibrate(scene: inout Scene, width: Int, height: Int) {
        let scale = max(1, max(width, height) / 512)
        let gw = max(width / scale, 16), gh = max(height / scale, 16)
        let g = makeGBuffer(samples: gw * gh)
        for _ in 0..<24 {
            guard let cb = gpu.queue.makeCommandBuffer() else { return }
            let slot = nextStatsSlot()
            guard let plan = makePlan(scene: scene, grid: Grid(width: gw, height: gh), cb: cb, blocking: true,
                                      statsSlot: slot),
                  let enc = cb.makeComputeCommandEncoder() else { return }
            encodeStatsReset(enc, slot: slot)
            encodeIterate(enc, plan: plan, gbuf: g, origin: .zero, size: SIMD2(UInt32(gw), UInt32(gh)),
                          bufOrigin: .zero, bufStride: UInt32(gw))
            encodeStatsSmooth(enc, slot: slot, alpha: 1)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            guard scene.iter.autoIterations else { return }
            let s = readStats(slot)
            let next = IterationTuner.adjust(maxIter: scene.iter.maxIter, stats: s, samples: gw * gh)
            if next == scene.iter.maxIter { return }
            scene.iter.maxIter = next
            if next < scene.iter.maxIter { return }
        }
    }

    /// Renders a still image tile by tile with `samples` anti-aliasing samples per pixel.
    public func renderStill(scene inScene: Scene, color: ColorSettings, options o: StillOptions,
                            progress: ((Double) -> Bool)? = nil) -> CGImage? {
        var scene = inScene
        resetSmoothing()
        calibrate(scene: &scene, width: o.width, height: o.height)
        let tile = min(o.tile, max(o.width, o.height))
        let g = makeGBuffer(samples: tile * tile)
        let acc = makeAccumulator(width: tile, height: tile)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tile, height: tile, mipmapped: false)
        outDesc.usage = [.shaderWrite, .shaderRead]
        outDesc.storageMode = .shared
        let out = gpu.device.makeTexture(descriptor: outDesc)!
        var pixels = [UInt8](repeating: 0, count: o.width * o.height * 4)
        let tilesX = (o.width + tile - 1) / tile, tilesY = (o.height + tile - 1) / tile
        let total = Double(tilesX * tilesY * o.samples)
        var done = 0.0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let x0 = tx * tile, y0 = ty * tile
                let w = min(tile, o.width - x0), h = min(tile, o.height - y0)
                var last: MTLCommandBuffer?
                for s in 0..<o.samples {
                    guard let cb = gpu.queue.makeCommandBuffer() else { return nil }
                    let slot = nextStatsSlot()
                    guard let plan = makePlan(scene: scene, grid: Grid(width: o.width, height: o.height, jitter: Engine.jitter(s)),
                                              cb: cb, blocking: true, statsSlot: slot),
                          let enc = cb.makeComputeCommandEncoder() else { return nil }
                    let origin = SIMD2(UInt32(x0), UInt32(y0))
                    encodeIterate(enc, plan: plan, gbuf: g, origin: origin, size: SIMD2(UInt32(w), UInt32(h)),
                                  bufOrigin: origin, bufStride: UInt32(w))
                    let size = SIMD2(UInt32(w), UInt32(h))
                    encodeColorize(enc, acc: acc, primary: GSource(buffer: g, size: size),
                                   fallback: nil, color: color, accumulate: s > 0, outSize: size)
                    if s == o.samples - 1 {
                        encodePresent(enc, acc: acc, dst: out, samples: o.samples, size: size)
                    }
                    enc.endEncoding()
                    cb.commit()
                    last = cb
                    done += 1
                    if s % 4 == 3 { cb.waitUntilCompleted() }
                    if let progress, !progress(done / total) { return nil }
                }
                last?.waitUntilCompleted()
                pixels.withUnsafeMutableBytes { raw in
                    let base = raw.baseAddress!.advanced(by: (y0 * o.width + x0) * 4)
                    out.getBytes(base, bytesPerRow: o.width * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
            }
        }
        return Engine.makeImage(pixels: pixels, width: o.width, height: o.height)
    }

    static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Automatic iteration limit from escape statistics.
public enum IterationTuner {
    public static let floor = 1000
    public static let ceiling = 100_000_000

    /// Doubles the limit while a noticeable share of samples escapes in its upper half (or none escape
    /// at all); lowers it when every escape happens far below the limit.
    public static func adjust(maxIter: Int, stats s: FSStats, samples: Int) -> Int {
        let esc = Int(s.escaped)
        if esc == 0 { return min(maxIter * 4, ceiling) }
        let late = Double(s.lateEscaped) / Double(max(samples, 1))
        if late > 0.0008 { return min(maxIter * 2, ceiling) }
        let hi = Int(s.maxIter)
        if hi < maxIter / 8 && maxIter > floor { return max(floor, hi * 3) }
        return maxIter
    }
}
