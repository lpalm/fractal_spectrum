import Foundation
import Metal
import CFractal

/// High-precision orbit of one point, stored in GPU-visible buffers, plus its BLA table.
public final class ReferenceOrbit: @unchecked Sendable {
    public let family: FractalFamily
    public let power: Int
    /// Julia parameter for orbits in a Julia set's plane; nil for parameter-plane orbits.
    public let juliaParameter: SIMD2<Double>?
    /// Start of the orbit: c for parameter-plane orbits (which start at 0), z0 for Julia orbits.
    public let center: PlanePoint
    public let precision: Int

    private let lock = NSLock()
    /// The orbit's points as floats (zero below the float range) and in extended range.
    private var pointsBuffer: MTLBuffer
    private var extendedPointsBuffer: MTLBuffer
    private var capacity: Int
    /// The C computation that extends the orbit.
    private let computation: OpaquePointer
    private var count = 0
    private var escaped = false
    private var computing = false
    private let cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let progressCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Length the current or last extension aims for.
    private(set) var requestedLength = 0

    /// Table matching the current point count; touched only by the thread that encodes GPU work.
    var blaTable: BLATable?

    init(formula: Formula, center: PlanePoint, precision: Int, capacity: Int) {
        family = formula.family
        power = formula.effectivePower
        juliaParameter = formula.juliaParameter
        self.center = center.withPrecision(precision)
        self.precision = precision
        self.capacity = max(capacity, 1024)
        (pointsBuffer, extendedPointsBuffer) = ReferenceOrbit.makeBuffers(capacity: self.capacity)
        computation = ReferenceOrbit.makeComputation(formula: formula, start: self.center, precision: precision)
        cancelFlag.pointee = 0
        progressCounter.pointee = 0
    }

    /// The C computation of the orbit that starts from `start`: c in the parameter plane (the orbit of 0),
    /// z0 in a Julia set.
    static func makeComputation(formula: Formula, start: PlanePoint, precision: Int) -> OpaquePointer {
        let family = formula.family.formulaID, power = Int32(formula.effectivePower)
        guard let julia = formula.juliaParameter else {
            return withExtendedLifetime(start) {
                fs_ref_new(family, power, start.re.handle, start.im.handle, nil, nil, precision)
            }
        }
        let jre = HPFloat(julia.x, precision: precision), jim = HPFloat(julia.y, precision: precision)
        return withExtendedLifetime((start, jre, jim)) {
            fs_ref_new(family, power, start.re.handle, start.im.handle, jre.handle, jim.handle, precision)
        }
    }

    deinit {
        fs_ref_free(computation)
        cancelFlag.deallocate()
        progressCounter.deallocate()
    }

    private static func makeBuffers(capacity: Int) -> (points: MTLBuffer, extendedPoints: MTLBuffer) {
        let device = GPU.shared.device
        return (device.makeBuffer(length: capacity * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!,
                device.makeBuffer(length: capacity * MemoryLayout<FSRefExt>.stride, options: .storageModeShared)!)
    }

    /// The published part of the orbit.
    struct Snapshot {
        var points: MTLBuffer
        var extendedPoints: MTLBuffer
        var count: Int
        var escaped: Bool
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(points: pointsBuffer, extendedPoints: extendedPointsBuffer, count: count, escaped: escaped) }
    }

    var isComputing: Bool { lock.withLock { computing } }

    /// Points computed so far, including those not yet published.
    var progressCount: Int { progressCounter.pointee }

    /// Whether the published orbit is complete up to `length` points (or escaped before).
    func covers(_ length: Int) -> Bool { lock.withLock { escaped || count >= length } }

    func cancel() { cancelFlag.pointee = 1 }

    /// Computes points until `length` exist or the orbit escapes. Blocks; call off the main thread.
    func extend(to length: Int) {
        lock.lock()
        if escaped || count >= length || computing {
            lock.unlock()
            return
        }
        computing = true
        requestedLength = length
        if length > capacity {
            let grown = max(length, capacity * 2)
            let (points, extendedPoints) = ReferenceOrbit.makeBuffers(capacity: grown)
            memcpy(points.contents(), pointsBuffer.contents(), count * MemoryLayout<SIMD2<Float>>.stride)
            memcpy(extendedPoints.contents(), extendedPointsBuffer.contents(), count * MemoryLayout<FSRefExt>.stride)
            pointsBuffer = points
            extendedPointsBuffer = extendedPoints
            capacity = grown
        }
        let points = pointsBuffer.contents().assumingMemoryBound(to: simd_float2.self)
        let extendedPoints = extendedPointsBuffer.contents().assumingMemoryBound(to: FSRefExt.self)
        lock.unlock()

        // the orbit stops once it escapes the escape radius that scenes use
        let bailout = IterationSettings().bailout
        let computed = fs_ref_run(computation, length, points, extendedPoints, bailout * bailout, cancelFlag, progressCounter)

        lock.withLock {
            count = computed
            escaped = fs_ref_escaped(computation) != 0
            computing = false
        }
    }
}

/// Picks, computes and caches reference orbits for perturbation rendering.
public final class ReferenceStore: @unchecked Sendable {
    private let lock = NSLock()
    /// The orbit in use, the one being prepared to replace it, and (for Julia sets) the critical orbit.
    private var current: ReferenceOrbit?
    private var pending: ReferenceOrbit?
    private var critical: ReferenceOrbit?
    private let queue = DispatchQueue(label: "fractal.reference", qos: .userInitiated)

    /// Called on the main queue whenever a background computation finishes.
    public var onUpdate: (@Sendable () -> Void)?

    public init() {}

    /// Progress of the reference orbit being computed, for the HUD.
    public struct Status: Sendable {
        public var computing: Bool
        public var progress: Double
    }

    public var status: Status {
        lock.withLock {
            for orbit in [pending, current].compactMap({ $0 }) where orbit.isComputing {
                let progress = orbit.requestedLength > 0 ? Double(orbit.progressCount) / Double(orbit.requestedLength) : 0
                return Status(computing: true, progress: progress)
            }
            return Status(computing: false, progress: 1)
        }
    }

    /// Whether `orbit` can serve `view`: same formula, enough precision, and a start within `slack`
    /// doublings of the view radius from the view centre.
    private func suits(_ orbit: ReferenceOrbit, _ formula: Formula, _ view: Viewport, precision: Int, slack: Double) -> Bool {
        guard orbit.family == formula.family, orbit.power == formula.effectivePower, orbit.precision >= precision,
              orbit.juliaParameter == formula.juliaParameter else { return false }
        return view.center.minus(orbit.center).log2Abs <= view.log2Radius + slack
    }

    /// Orbit of the critical point 0 for a Julia set's parameter: the target Julia samples rebase onto.
    /// Returns nil while it is being computed (unless `blocking`).
    func criticalOrbit(formula: Formula, precision: Int, length: Int, blocking: Bool) -> ReferenceOrbit? {
        let parameterPlane = formula.parameterPlane
        let c = SIMD2(formula.juliaRe, formula.juliaIm)
        let orbit: ReferenceOrbit = lock.withLock {
            if let existing = critical, existing.family == parameterPlane.family,
               existing.power == parameterPlane.effectivePower, existing.precision >= precision,
               existing.center.re.doubleValue == c.x, existing.center.im.doubleValue == c.y {
                return existing
            }
            critical?.cancel()
            let bits = precision + 64   // headroom: the orbit keeps serving some 64 doublings deeper
            let orbit = ReferenceOrbit(formula: parameterPlane,
                                       center: PlanePoint(re: HPFloat(c.x, precision: bits), im: HPFloat(c.y, precision: bits)),
                                       precision: bits, capacity: length + 1)
            critical = orbit
            return orbit
        }
        if !orbit.covers(length) && !orbit.isComputing {
            if blocking {
                orbit.extend(to: length)
            } else {
                queue.async { [weak self] in
                    orbit.extend(to: length)
                    DispatchQueue.main.async { self?.onUpdate?() }
                }
                return orbit.snapshot.count >= 2 && !orbit.isComputing ? orbit : nil
            }
        }
        return orbit.isComputing ? nil : orbit
    }

    /// Returns a reference usable for `view`, starting background work when a better one is needed.
    /// With `blocking`, waits until an ideal reference is complete.
    func reference(formula: Formula, view: Viewport, minSide: Double, length: Int, focus: Focus? = nil,
                   blocking: Bool) -> ReferenceOrbit? {
        let precision = view.requiredPrecision(minSide: minSide)
        // A new orbit anchored at the focus gets the precision of the destination, so it serves the whole motion.
        var focusView = view
        if let f = focus { focusView.log2Radius = min(f.log2Radius, view.log2Radius) }
        let newPrecision = max(precision, focusView.requiredPrecision(minSide: minSide)) + 64   // headroom, as above
        func suits(_ orbit: ReferenceOrbit, slack: Double) -> Bool {
            self.suits(orbit, formula, view, precision: precision, slack: slack)
        }

        lock.lock()
        if let p = pending, !p.isComputing, p.covers(length) || p.snapshot.escaped, suits(p, slack: 10) {
            current = p
            pending = nil
        }
        var usable: ReferenceOrbit?
        var toExtend: ReferenceOrbit?
        if let current, suits(current, slack: 3) {
            usable = current
            if !current.covers(length) && !current.isComputing { toExtend = current }
        } else {
            if let pending, suits(pending, slack: 3) {
                if !pending.covers(length) && !pending.isComputing { toExtend = pending }
            } else {
                pending?.cancel()
                let orbit = ReferenceOrbit(formula: formula, center: focus?.point ?? view.center, precision: newPrecision,
                                           capacity: length + 1)
                pending = orbit
                toExtend = orbit
            }
            // meanwhile the current orbit serves if it is not too far off
            if let current, suits(current, slack: 10) { usable = current }
        }
        lock.unlock()

        if let toExtend {
            if blocking {
                toExtend.extend(to: length)
            } else {
                queue.async { [weak self] in
                    toExtend.extend(to: length)
                    DispatchQueue.main.async { self?.onUpdate?() }
                }
            }
        }
        guard blocking else { return usable }
        return lock.withLock {
            if let p = pending, p === toExtend || (p.covers(length) && suits(p, slack: 10)) {
                current = p
                pending = nil
            }
            return current.flatMap { suits($0, slack: 10) ? $0 : nil }
        }
    }

    /// Drops all references (e.g. when memory matters or the formula changed).
    public func reset() {
        lock.withLock {
            pending?.cancel()
            pending = nil
            current = nil
            critical?.cancel()
            critical = nil
        }
    }
}

/// Bilinear-approximation table for one reference orbit, built on the GPU: level k holds the maps
/// that skip 2^k iterations from every 2^k-th orbit point, each valid while |delta| stays below its
/// radius.
final class BLATable {
    let entries: MTLBuffer
    /// Validity radius of each entry, squared (float) and as log2 (for extended-range deltas).
    let radius2: MTLBuffer
    let log2Radius: MTLBuffer
    /// log2 of the smallest |Z| each entry steps over (for interior detection).
    let log2MinZ: MTLBuffer
    /// Largest level-0 radius squared (float bits), for skipping hopeless lookups.
    let maxRadius2: MTLBuffer
    /// First entry and entry count of each level.
    let offsets: [UInt32]
    let counts: [UInt32]
    /// log2 of the largest |dc| the table is valid for, and of its relative error tolerance.
    let log2C: Double
    let log2Eps: Double
    /// Orbit points the table was built from.
    let orbitLength: Int

    /// Builds the table on the GPU. `reuse` donates its buffers when large enough; callers pass it only
    /// when no submitted work can still be reading that table.
    init?(encodingInto encoder: MTLComputeCommandEncoder, snapshot: ReferenceOrbit.Snapshot, formula: Formula,
          log2C: Double, log2Eps: Double, reuse old: BLATable? = nil) {
        let levelZeroCount = snapshot.count - 2
        guard levelZeroCount >= 1 else { return nil }
        var offsets: [UInt32] = []
        var counts: [UInt32] = []
        var total = 0
        var levelCount = levelZeroCount
        while levelCount >= 1 && offsets.count < Int(FS_MAX_BLA_LEVELS) {
            offsets.append(UInt32(total))
            counts.append(UInt32(levelCount))
            total += levelCount
            if levelCount < 2 { break }
            levelCount /= 2
        }
        self.offsets = offsets
        self.counts = counts
        self.log2C = log2C
        self.log2Eps = log2Eps
        orbitLength = snapshot.count
        let device = GPU.shared.device
        if let old, old.entries.length >= total * MemoryLayout<FSBLAEntry>.stride {
            entries = old.entries
            radius2 = old.radius2
            log2Radius = old.log2Radius
            log2MinZ = old.log2MinZ
            maxRadius2 = old.maxRadius2
        } else {
            // room to grow with the orbit before the next reallocation
            let capacity = total + total / 2
            maxRadius2 = device.makeBuffer(length: 16, options: .storageModePrivate)!
            entries = device.makeBuffer(length: capacity * MemoryLayout<FSBLAEntry>.stride, options: .storageModePrivate)!
            radius2 = device.makeBuffer(length: capacity * 4, options: .storageModePrivate)!
            log2Radius = device.makeBuffer(length: capacity * 4, options: .storageModePrivate)!
            log2MinZ = device.makeBuffer(length: capacity * 4, options: .storageModePrivate)!
        }

        let gpu = GPU.shared
        var key = GPU.PipelineKey(name: "bla_init", family: formula.family.formulaID, power: Int32(formula.effectivePower))
        let initPipeline = gpu.pipeline(key)
        key.name = "bla_merge"
        let mergePipeline = gpu.pipeline(key)
        encoder.setBuffer(entries, offset: 0, index: 0)
        encoder.setBuffer(radius2, offset: 0, index: 1)
        encoder.setBuffer(log2Radius, offset: 0, index: 2)
        encoder.setBuffer(snapshot.extendedPoints, offset: 0, index: 3)
        encoder.setBuffer(log2MinZ, offset: 0, index: 5)
        encoder.setBuffer(maxRadius2, offset: 0, index: 6)
        gpu.dispatch1D(encoder, gpu.pipeline("bla_reset_max"), count: 1)
        var params = FSBLABuildParams(count: UInt32(levelZeroCount), srcOffset: 0, dstOffset: 0,
                                      log2Eps: Float(log2Eps), log2C: Float(max(log2C, -1e30)), pad0: 0, pad1: 0, pad2: 0)
        encoder.setBytes(&params, length: MemoryLayout<FSBLABuildParams>.stride, index: 4)
        gpu.dispatch1D(encoder, initPipeline, count: levelZeroCount)
        // each level merges pairs of the level below
        for level in 1..<offsets.count {
            params.count = counts[level]
            params.srcOffset = offsets[level - 1]
            params.dstOffset = offsets[level]
            encoder.setBytes(&params, length: MemoryLayout<FSBLABuildParams>.stride, index: 4)
            gpu.dispatch1D(encoder, mergePipeline, count: Int(counts[level]))
        }
    }
}

extension Formula {
    /// The first `count` points of the orbit of `point` (z_0 = 0 with c = point, or z_0 = point in a
    /// Julia set), in double precision, ending early once |z| exceeds 4 (for display).
    public func orbit(of point: PlanePoint, count: Int) -> [SIMD2<Float>] {
        let computation = ReferenceOrbit.makeComputation(formula: self, start: point.withPrecision(53), precision: 53)
        defer { fs_ref_free(computation) }
        var points = [SIMD2<Float>](repeating: .zero, count: count)
        var extendedPoints = [FSRefExt](repeating: FSRefExt(), count: count)
        let computed = fs_ref_run(computation, count, &points, &extendedPoints, 16, nil, nil)
        return Array(points.prefix(computed))
    }
}
