import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CFractal

/// Turns scenes into G-buffers (per-sample iteration results) and G-buffers into colours; shared by
/// the interactive view and exports.
public final class Engine: @unchecked Sendable {
    public let gpu = GPU.shared
    /// Each engine has its own queue so offline renders never wait behind interactive passes or vice versa.
    public let queue: MTLCommandQueue
    public let palettes: PaletteBank
    public let references = ReferenceStore()
    /// Escape statistics of recent passes, one `FSStats` per slot.
    let statsBuffer: MTLBuffer
    /// The colour origin: the escape time at the start of the palette (float4: origin, -, -, set).
    let colorOriginBuffer: MTLBuffer
    /// Bound in place of absent inputs.
    private let placeholderBuffer: MTLBuffer
    private let placeholderTexture: MTLTexture
    private var lastStatsSlot: UInt32 = 0
    /// Passes in flight at once never come near this many.
    private static let statsSlots: UInt32 = 256

    public init() {
        let device = gpu.device
        queue = device.makeCommandQueue()!
        palettes = PaletteBank(device: device)
        statsBuffer = device.makeBuffer(length: Int(Engine.statsSlots) * MemoryLayout<FSStats>.stride,
                                        options: .storageModeShared)!
        assert(MemoryLayout<FSStats>.stride == 32)
        colorOriginBuffer = device.makeBuffer(length: 16, options: .storageModeShared)!
        memset(colorOriginBuffer.contents(), 0, 16)
        placeholderBuffer = device.makeBuffer(length: 256, options: .storageModePrivate)!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        placeholderTexture = device.makeTexture(descriptor: descriptor)!
    }

    /// A statistics slot for the next pass.
    public func nextStatsSlot() -> UInt32 {
        lastStatsSlot = (lastStatsSlot + 1) % Engine.statsSlots
        return lastStatsSlot
    }

    /// Escape statistics of a finished pass.
    public func readStats(_ slot: UInt32) -> FSStats {
        statsBuffer.contents().assumingMemoryBound(to: FSStats.self)[Int(slot)]
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
        var reference: ReferenceOrbit.Snapshot?
        var blaTable: BLATable?
        /// Julia sets: the orbit of the critical point, which samples rebase onto, and its table.
        var criticalReference: ReferenceOrbit.Snapshot?
        var criticalBLATable: BLATable?
        public var perturbed: Bool
        public var deep: Bool
        public var effectiveMaxIter: Int
        public var usedBLA: Bool { blaTable != nil }
    }

    /// Prepares a pass; returns nil while a needed reference orbit is still being computed (unless
    /// `blocking`). Encodes BLA table construction into `encoder` when a table must be (re)built.
    /// `focus`: where the camera is heading, for placing a new reference orbit.
    /// `exclusive`: no earlier submitted pass can still read this engine's tables, so a rebuild may
    /// reuse their buffers.
    /// `interior`: compile in attracting-cycle detection (worth it only when the view contains interior).
    public func makePlan(scene: FractalScene, grid: Grid, encoder: MTLComputeCommandEncoder, blocking: Bool,
                         focus: Focus? = nil, statsSlot: UInt32, exclusive: Bool = false,
                         interior: Bool = true) -> Plan? {
        let formula = scene.formula, view = scene.view
        let log2Step = view.log2Step(width: grid.width, height: grid.height)
        let maxIter = max(scene.iter.maxIter, 16)
        var params = iterationParams(scene: scene, grid: grid, log2Step: log2Step, maxIter: maxIter, statsSlot: statsSlot)
        var key = GPU.PipelineKey(name: "iterate_direct", formula: formula.family.formulaID,
                                  power: Int32(formula.effectivePower), julia: formula.julia,
                                  derivative: scene.iter.derivative)

        // Floats resolve samples this far apart around the view centre; deeper views iterate each
        // sample's difference from a reference orbit instead.
        guard log2Step < -18 else {
            params.offsetM = SIMD2(Float(view.center.re.doubleValue), Float(view.center.im.doubleValue))
            return Plan(params: params, pipeline: gpu.pipeline(key), perturbed: false, deep: false,
                        effectiveMaxIter: maxIter)
        }
        let minSide = Double(min(grid.width, grid.height))
        guard let reference = references.reference(formula: formula, view: view, minSide: minSide,
                                                   length: maxIter + 1, focus: focus, blocking: blocking) else { return nil }
        let orbit = reference.snapshot
        guard orbit.count >= 2 else { return nil }
        var critical: ReferenceOrbit?
        if formula.julia {
            guard let c = references.criticalOrbit(formula: formula, precision: view.requiredPrecision(minSide: minSide),
                                                   length: maxIter + 1, blocking: blocking),
                  c.snapshot.count >= 2 else { return nil }
            critical = c
        }
        let offset = view.center.minus(reference.center)
        (params.offsetM, params.offsetE) = offset.shared
        let effectiveMaxIter = orbit.escaped ? maxIter : min(maxIter, orbit.count - 1)
        params.maxIter = UInt32(effectiveMaxIter)
        params.refLen = UInt32(orbit.count)

        // The largest |dc| over the grid, log2(|offset| + half diagonal), decides how far each
        // approximation may reach; Julia sets have no dc.
        let log2HalfDiagonal = log2Step + log2(0.5 * hypot(Double(grid.width), Double(grid.height)))
        let log2Offset = offset.log2Abs
        let log2C = formula.julia ? -1e30
            : log2Offset.isFinite ? max(log2Offset, log2HalfDiagonal) + log2(1 + exp2(-abs(log2Offset - log2HalfDiagonal)))
            : log2HalfDiagonal
        let log2Eps = scene.iter.blaLog2Eps
        /// The orbit's table, rebuilt (with twice the reach needed) unless the current one reaches
        /// far enough without being more than 16 times too cautious.
        func blaTable(of orbit: ReferenceOrbit, _ snapshot: ReferenceOrbit.Snapshot, formula: Formula) -> BLATable? {
            guard scene.iter.useBLA else { return nil }
            if let t = orbit.bla, t.orbitLength == snapshot.count, t.log2Eps == log2Eps, log2C <= t.log2C,
               log2C >= t.log2C - 4 { return t }
            let t = BLATable(encodingInto: encoder, snapshot: snapshot, formula: formula, log2C: log2C + 1,
                             log2Eps: log2Eps, reuse: exclusive ? orbit.bla : nil)
            orbit.bla = t
            return t
        }
        let table = blaTable(of: reference, orbit, formula: formula)
        if let table {
            params.blaLevels = UInt32(table.offsets.count)
            copy(table.offsets, into: &params.blaOffset)
            copy(table.counts, into: &params.blaCount)
        }
        var criticalOrbit: ReferenceOrbit.Snapshot?
        var criticalTable: BLATable?
        if let critical {
            var parameterPlane = formula
            parameterPlane.julia = false
            let snapshot = critical.snapshot
            criticalOrbit = snapshot
            criticalTable = blaTable(of: critical, snapshot, formula: parameterPlane)
            params.refLen2 = UInt32(snapshot.count)
            if let t = criticalTable {
                params.blaLevels2 = UInt32(t.offsets.count)
                copy(t.offsets, into: &params.blaOffset2)
                copy(t.counts, into: &params.blaCount2)
            }
        }
        // Views this deep may need extended-range deltas (the kernel's DEEP variant).
        let deep = log2Step < -50
        key.name = "iterate_perturb"
        key.useBLA = table != nil
        key.deep = deep
        key.interior = interior
        return Plan(params: params, pipeline: gpu.pipeline(key), reference: orbit, blaTable: table,
                    criticalReference: criticalOrbit, criticalBLATable: criticalTable, perturbed: true, deep: deep,
                    effectiveMaxIter: effectiveMaxIter)
    }

    /// Kernel parameters of a pass before any reference orbit is involved: where its samples lie in
    /// the plane and when they escape.
    private func iterationParams(scene: FractalScene, grid: Grid, log2Step: Double, maxIter: Int,
                                 statsSlot: UInt32) -> FSIterParams {
        let formula = scene.formula
        let step = FloatExp.fromLog2(log2Step)
        let basis = scene.view.basis(flipY: formula.family.flipY)
        var params = FSIterParams()
        params.size = SIMD2(UInt32(grid.width), UInt32(grid.height))
        params.bufStride = UInt32(grid.width)
        params.stepX = SIMD2<Float>(basis.x * step.m)
        params.stepY = SIMD2<Float>(basis.y * step.m)
        params.stepE = Int32(step.e)
        params.jitter = grid.jitter
        params.juliaC = SIMD2(Float(formula.juliaRe), Float(formula.juliaIm))
        params.bailout2 = Float(scene.iter.bailout * scene.iter.bailout)
        params.log2Bailout2 = log2(params.bailout2)
        params.invLog2Power = 1 / log2(Float(formula.effectivePower))
        params.log2Step = Float(log2Step)
        params.statsSlot = statsSlot
        params.maxIter = UInt32(maxIter)
        return params
    }

    /// Iterates the samples of `origin ..< origin + size` into `gBuffer`, laid out from `bufferOrigin`
    /// with rows of `bufferStride` samples.
    public func encodeIterate(_ encoder: MTLComputeCommandEncoder, plan: Plan, into gBuffer: MTLBuffer,
                              origin: SIMD2<UInt32>, size: SIMD2<UInt32>,
                              bufferOrigin: SIMD2<UInt32>, bufferStride: UInt32) {
        var params = plan.params
        params.origin = origin
        params.workSize = size
        params.bufOrigin = bufferOrigin
        params.bufStride = bufferStride
        encoder.setBuffer(gBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<FSIterParams>.stride, index: 1)
        if let reference = plan.reference {
            // indices as in the signature of `iterate_perturb`
            func bind(_ buffer: MTLBuffer?, _ index: Int) {
                encoder.setBuffer(buffer ?? placeholderBuffer, offset: 0, index: index)
            }
            let table = plan.blaTable, critical = plan.criticalReference, criticalTable = plan.criticalBLATable
            bind(reference.points, 2)
            bind(reference.extendedPoints, 3)
            bind(table?.entries, 4)
            bind(table?.radius2, 5)
            bind(table?.log2Radius, 6)
            bind(table?.log2MinZ, 8)
            bind(critical?.points, 9)
            bind(critical?.extendedPoints, 10)
            bind(criticalTable?.entries, 11)
            bind(criticalTable?.radius2, 12)
            bind(criticalTable?.log2Radius, 13)
            bind(criticalTable?.log2MinZ, 14)
            bind(table?.maxRadius2, 15)
            bind(criticalTable?.maxRadius2, 16)
        }
        encoder.setBuffer(statsBuffer, offset: 0, index: 7)
        gpu.dispatch2D(encoder, plan.pipeline, width: Int(size.x), height: Int(size.y))
    }

    public func encodeStatsReset(_ encoder: MTLComputeCommandEncoder, slot: UInt32) {
        var slot = slot
        encoder.setBuffer(statsBuffer, offset: 0, index: 7)
        encoder.setBytes(&slot, length: 4, index: 0)
        gpu.dispatch1D(encoder, gpu.pipeline("stats_reset"), count: 1)
    }

    /// Octaves of escape time a view keeps above the colour origin (see the `color_origin` kernel).
    static let colorSpan: Float = 8
    /// Zoom, in doublings, over which the colour origin covers most of the way to a new target.
    static let colorOriginDoublings = 3.0

    /// Moves the colour origin towards what a finished pass's statistics call for, in proportion to
    /// the zoom since the last update (`zoomed`, in doublings); nil snaps to the pass (a new view).
    public func encodeColorOrigin(_ encoder: MTLComputeCommandEncoder, slot: UInt32, zoomed: Double?) {
        let rate = zoomed.map { Float(1 - exp(-abs($0) / Engine.colorOriginDoublings)) } ?? 1
        var args = SIMD3<Float>(Float(slot), rate, Engine.colorSpan)
        encoder.setBuffer(statsBuffer, offset: 0, index: 7)
        encoder.setBuffer(colorOriginBuffer, offset: 0, index: 0)
        encoder.setBytes(&args, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        gpu.dispatch1D(encoder, gpu.pipeline("color_origin"), count: 1)
    }

    /// The escape time at the start of the palette; nil until a pass has set it (the next one snaps).
    public var colorOrigin: Float? {
        get {
            let origin = colorOriginBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee
            return origin.w == 0 ? nil : origin.x
        }
        set {
            colorOriginBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee =
                newValue.map { SIMD4($0, 0, 0, 1) } ?? .zero
        }
    }

    /// The top-left `size` samples of a G-buffer.
    public struct GBufferRegion {
        public var buffer: MTLBuffer
        public var size: SIMD2<UInt32>

        public init(buffer: MTLBuffer, size: SIMD2<UInt32>) {
            self.buffer = buffer
            self.size = size
        }
    }

    /// Partially finished primary pass: tiles not yet computed show the coloured preview instead.
    public struct TileFallback {
        public var preview: MTLTexture
        public var previewSize: SIMD2<UInt32>
        /// One flag per tile, non-zero once the tile is computed.
        public var tileDone: MTLBuffer
        /// Tiles per axis.
        public var grid: SIMD2<UInt32>
        public var tileSize: UInt32

        public init(preview: MTLTexture, previewSize: SIMD2<UInt32>, tileDone: MTLBuffer, grid: SIMD2<UInt32>,
                    tileSize: UInt32) {
            self.preview = preview
            self.previewSize = previewSize
            self.tileDone = tileDone
            self.grid = grid
            self.tileSize = tileSize
        }
    }

    /// A cross-fade from one palette to another.
    public struct PaletteBlend: Sendable, Equatable {
        public var from: Int
        public var to: Int
        public var mix: Float

        public init(from: Int, to: Int, mix: Float) {
            self.from = from
            self.to = to
            self.mix = mix
        }
    }

    private func colorParams(_ color: ColorSettings, blend: PaletteBlend?, gBufferSize: SIMD2<UInt32>,
                             outputSize: SIMD2<UInt32>) -> FSColorParams {
        var params = FSColorParams()
        params.outSize = outputSize
        params.gSize = gBufferSize
        params.density = Float(color.density)
        params.offset = Float(color.offset)
        params.mapping = Int32(color.mapping)
        params.deScale = Float(log2(Double(max(1, min(gBufferSize.x, gBufferSize.y))) / 2))
        params.lightAzimuth = Float(color.lightAzimuth)
        params.lightElevation = Float(color.lightElevation)
        params.lightStrength = Float(color.lightStrength)
        params.edgeStrength = Float(color.edgeStrength)
        params.paletteCount = Float(palettes.count)
        params.paletteRow = Float(blend?.from ?? color.palette)
        params.paletteRowB = Float(blend?.to ?? color.palette)
        params.paletteMix = blend?.mix ?? 0
        params.interior = SIMD4(color.interior, 1)
        params.tileGrid = SIMD2(1, 1)
        params.tileSize = 1
        return params
    }

    /// Colours a full-resolution G-buffer (`size`, by default the accumulator's) into the accumulator,
    /// replacing its contents or adding a sample.
    public func encodeColorize(_ encoder: MTLComputeCommandEncoder, into accumulator: MTLTexture,
                               from primary: GBufferRegion, fallback: TileFallback?, color: ColorSettings,
                               blend: PaletteBlend? = nil, accumulate: Bool, size: SIMD2<UInt32>? = nil) {
        let size = size ?? SIMD2(UInt32(accumulator.width), UInt32(accumulator.height))
        var params = colorParams(color, blend: blend, gBufferSize: primary.size, outputSize: size)
        params.accumulate = accumulate ? 1 : 0
        if let fallback {
            params.useFallback = 1
            params.fbSize = fallback.previewSize
            params.tileGrid = fallback.grid
            params.tileSize = fallback.tileSize
        }
        encoder.setTexture(accumulator, index: 0)
        encoder.setTexture(palettes.texture, index: 1)
        encoder.setTexture(fallback?.preview ?? placeholderTexture, index: 2)
        encoder.setBuffer(primary.buffer, offset: 0, index: 0)
        encoder.setBuffer(fallback?.tileDone ?? placeholderBuffer, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<FSColorParams>.stride, index: 3)
        encoder.setBuffer(colorOriginBuffer, offset: 0, index: 4)
        gpu.dispatch2D(encoder, gpu.pipeline("colorize"), width: Int(size.x), height: Int(size.y))
    }

    /// Colours a G-buffer at its own resolution into `image`.
    public func encodeShade(_ encoder: MTLComputeCommandEncoder, from source: GBufferRegion, into image: MTLTexture,
                            color: ColorSettings, blend: PaletteBlend? = nil) {
        var params = colorParams(color, blend: blend, gBufferSize: source.size, outputSize: source.size)
        encoder.setTexture(image, index: 0)
        encoder.setTexture(palettes.texture, index: 1)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<FSColorParams>.stride, index: 3)
        encoder.setBuffer(colorOriginBuffer, offset: 0, index: 4)
        gpu.dispatch2D(encoder, gpu.pipeline("shade_samples"), width: Int(source.size.x), height: Int(source.size.y))
    }

    /// Bilinearly scales the top-left `size` region of `image` into the accumulator (as one sample).
    public func encodeUpsample(_ encoder: MTLComputeCommandEncoder, from image: MTLTexture, size: SIMD2<UInt32>,
                               into accumulator: MTLTexture, outputSize: SIMD2<UInt32>) {
        var params = FSColorParams()
        params.gSize = size
        params.outSize = outputSize
        encoder.setTexture(image, index: 0)
        encoder.setTexture(accumulator, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<FSColorParams>.stride, index: 3)
        gpu.dispatch2D(encoder, gpu.pipeline("upsample"), width: Int(outputSize.x), height: Int(outputSize.y))
    }

    /// A colour image of the given size, for coloured previews.
    public func makeColorTexture(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return gpu.device.makeTexture(descriptor: descriptor)!
    }

    /// Maps output pixels into the accumulator: identity, or an affine reprojection between two views
    /// (centred output pixel q samples the accumulator at A q + b, centred; A is row-major).
    public struct Reprojection: Sendable {
        public var A: SIMD4<Float>
        public var b: SIMD2<Float>
        public var identity: Bool

        public static let identity = Reprojection(A: SIMD4(1, 0, 0, 1), b: .zero, identity: true)

        public init(A: SIMD4<Float>, b: SIMD2<Float>, identity: Bool) {
            self.A = A
            self.b = b
            self.identity = identity
        }
    }

    /// Resolves the accumulator (the average of its samples) into a displayable image: sRGB with
    /// dither, or extended-range linear Display P3 with the display's `hdrHeadroom`. `background`
    /// (linear) fills what the reprojection brings in from outside the accumulator's `sourceSize`.
    public func encodePresent(_ encoder: MTLComputeCommandEncoder, from accumulator: MTLTexture, into target: MTLTexture,
                              reprojection: Reprojection = .identity, sourceSize: SIMD2<UInt32>? = nil,
                              background: SIMD3<Float>, size: SIMD2<UInt32>? = nil, hdrHeadroom: Float? = nil) {
        var params = FSPresentParams()
        params.hdr = hdrHeadroom == nil ? 0 : 1
        params.headroom = hdrHeadroom ?? 1
        params.size = size ?? SIMD2(UInt32(target.width), UInt32(target.height))
        params.srcSize = sourceSize ?? SIMD2(UInt32(accumulator.width), UInt32(accumulator.height))
        params.identity = reprojection.identity && params.srcSize == params.size ? 1 : 0
        params.A = reprojection.A
        params.b = reprojection.b
        params.background = SIMD4(background, 1)
        encoder.setTexture(accumulator, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<FSPresentParams>.stride, index: 0)
        gpu.dispatch2D(encoder, gpu.pipeline("present"), width: Int(params.size.x), height: Int(params.size.y))
    }

    /// A G-buffer for `samples` samples (16 bytes each, GPU only).
    public func makeGBuffer(samples: Int) -> MTLBuffer {
        gpu.device.makeBuffer(length: max(samples, 1) * 16, options: .storageModePrivate)!
    }

    /// An image that sums colour samples (alpha counts them).
    public func makeAccumulator(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return gpu.device.makeTexture(descriptor: descriptor)!
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

/// Copies `values` to the start of a fixed-size C array, which Swift imports as a tuple.
private func copy<CArray>(_ values: [UInt32], into array: inout CArray) {
    withUnsafeMutableBytes(of: &array) { raw in
        let slots = raw.bindMemory(to: UInt32.self)
        for (i, value) in values.enumerated() { slots[i] = value }
    }
}

// MARK: - Still images

extension Engine {
    /// Size and quality of a still image.
    public struct StillOptions: Sendable {
        public var width: Int
        public var height: Int
        /// Anti-aliasing samples per pixel.
        public var samples: Int
        /// Colour origin to use (e.g. the live view's, so the image keeps its colours); set from the
        /// image when nil.
        public var colorOrigin: Float?

        public init(width: Int, height: Int, samples: Int, colorOrigin: Float? = nil) {
            self.width = width
            self.height = height
            self.samples = samples
            self.colorOrigin = colorOrigin
        }
    }

    /// Still images render in square tiles of at most this many pixels per side, bounding memory.
    static let stillTileSize = 2048

    /// Prints each step of `calibrate`'s iteration tuning.
    public static var traceTuning = false

    /// Runs low-resolution passes to set the colour origin (unless `updateColors` is false) and, with
    /// automatic iterations, the iteration limit.
    public func calibrate(scene: inout FractalScene, width: Int, height: Int, updateColors: Bool = true) {
        let scale = max(1, max(width, height) / 512)
        let gw = max(width / scale, 16), gh = max(height / scale, 16)
        let gBuffer = makeGBuffer(samples: gw * gh)
        for _ in 0..<24 {
            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            let slot = nextStatsSlot()
            guard let plan = makePlan(scene: scene, grid: Grid(width: gw, height: gh), encoder: encoder, blocking: true,
                                      statsSlot: slot) else {
                encoder.endEncoding()
                commandBuffer.commit()
                return
            }
            encodeStatsReset(encoder, slot: slot)
            encodeIterate(encoder, plan: plan, into: gBuffer, origin: .zero, size: SIMD2(UInt32(gw), UInt32(gh)),
                          bufferOrigin: .zero, bufferStride: UInt32(gw))
            if updateColors { encodeColorOrigin(encoder, slot: slot, zoomed: nil) }
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard scene.iter.autoIterations else { return }
            let stats = readStats(slot)
            let gpuMs = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
            let maxIter = scene.iter.maxIter
            let next = IterationTuner.adjustOffline(maxIter: maxIter, stats: stats, samples: gw * gh, gpuMs: gpuMs)
            if Engine.traceTuning {
                print("tune maxIter \(maxIter): esc \(stats.escaped) late \(stats.lateEscaped) unresolved \(stats.unresolved) interior \(stats.interior) hi \(stats.maxIter) of \(gw * gh) \(String(format: "%.1f", gpuMs)) ms -> \(next)")
            }
            scene.iter.maxIter = next
            // a lower limit still shows every escape, so only a raised one needs another look
            if next <= maxIter { return }
        }
    }

    /// Renders a still image tile by tile with `options.samples` anti-aliasing samples per pixel.
    /// `progress` returns false to cancel.
    public func renderStill(scene: FractalScene, color: ColorSettings, options: StillOptions,
                            progress: ((Double) -> Bool)? = nil) -> CGImage? {
        var scene = scene
        let (width, height) = (options.width, options.height)
        colorOrigin = options.colorOrigin
        calibrate(scene: &scene, width: width, height: height, updateColors: options.colorOrigin == nil)
        let tile = min(Engine.stillTileSize, max(width, height))
        let gBuffer = makeGBuffer(samples: tile * tile)
        let accumulator = makeAccumulator(width: tile, height: tile)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tile, height: tile,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let tileImage = gpu.device.makeTexture(descriptor: descriptor)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let tilesX = (width + tile - 1) / tile, tilesY = (height + tile - 1) / tile
        let passes = Double(tilesX * tilesY * options.samples)
        var finishedPasses = 0.0
        let paced = PacedEncoder(queue: queue)
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let x0 = tx * tile, y0 = ty * tile
                let w = min(tile, width - x0), h = min(tile, height - y0)
                let size = SIMD2(UInt32(w), UInt32(h))
                for sample in 0..<options.samples {
                    let slot = nextStatsSlot()
                    let grid = Grid(width: width, height: height, jitter: Engine.jitter(sample))
                    guard let plan = makePlan(scene: scene, grid: grid, encoder: paced.encoder, blocking: true,
                                              statsSlot: slot) else { return nil }
                    paced.iterate(self, plan: plan, into: gBuffer, origin: SIMD2(x0, y0), size: SIMD2(w, h),
                                  bufferOrigin: SIMD2(UInt32(x0), UInt32(y0)), bufferStride: UInt32(w))
                    encodeColorize(paced.encoder, into: accumulator, from: GBufferRegion(buffer: gBuffer, size: size),
                                   fallback: nil, color: color, accumulate: sample > 0, size: size)
                    if sample == options.samples - 1 {
                        encodePresent(paced.encoder, from: accumulator, into: tileImage, sourceSize: size,
                                      background: color.interior, size: size)
                    }
                    finishedPasses += 1
                    if let progress, !progress(finishedPasses / passes) { return nil }
                }
                paced.sync()
                pixels.withUnsafeMutableBytes { raw in
                    let tileStart = raw.baseAddress!.advanced(by: (y0 * width + x0) * 4)
                    tileImage.getBytes(tileStart, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
            }
        }
        return Engine.makeImage(pixels: pixels, width: width, height: height)
    }

    /// An sRGB image of RGBX pixels.
    public static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Automatic iteration limit from escape statistics.
public enum IterationTuner {
    public static let floor = 1000
    public static let ceiling = 100_000_000
    /// Offline renders raise the limit only while a sample costs less than this many GPU µs on
    /// average (about four times the interactive view's budget).
    public static let offlineMicrosPerSample = 1.6

    /// Cost of a pass after raising the limit from `maxIter` to `next`: unresolved samples run to the
    /// new limit, the others cost the same.
    public static func grownCost(_ cost: Double, stats s: FSStats, samples: Int, maxIter: Int, next: Int) -> Double {
        let n = Double(max(samples, 1))
        let mean = max(Double(s.iterations) / n, 1)
        return cost * (mean + Double(s.unresolved) / n * Double(next - maxIter)) / mean
    }

    /// Doubles the limit while a noticeable share of samples is still unresolved (hit the limit
    /// without escaping or showing an attracting cycle) and escapes still happen near the limit;
    /// lowers it when every escape happens far below the limit.
    public static func adjust(maxIter: Int, stats s: FSStats, samples: Int) -> Int {
        let n = Double(max(samples, 1))
        let unresolved = Double(s.unresolved) / n
        if s.escaped == 0 { return unresolved > 0.01 ? min(maxIter * 4, ceiling) : maxIter }
        let late = Double(s.lateEscaped) / n
        if unresolved > 0.01 && late > 0.01 { return min(maxIter * 2, ceiling) }
        let hi = Int(s.maxIter)
        if hi < maxIter / 8 && unresolved < 0.0005 && maxIter > floor { return max(floor, hi * 3) }
        return maxIter
    }

    /// `adjust` for offline renders: a raise must keep the average sample within
    /// `offlineMicrosPerSample`. `stats` describe one pass of `samples` samples; `gpuMs` may cover
    /// `passes` such passes (anti-aliasing samples).
    public static func adjustOffline(maxIter: Int, stats: FSStats, samples: Int, gpuMs: Double, passes: Int = 1) -> Int {
        let next = adjust(maxIter: maxIter, stats: stats, samples: samples)
        guard next > maxIter else { return next }
        let grown = grownCost(gpuMs, stats: stats, samples: samples, maxIter: maxIter, next: next)
        return grown * 1000 / Double(samples * max(passes, 1)) <= offlineMicrosPerSample ? next : maxIter
    }
}
