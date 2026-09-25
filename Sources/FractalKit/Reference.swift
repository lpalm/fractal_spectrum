import Foundation
import Metal
import CFractal

/// High-precision orbit of one point, stored in GPU-visible buffers, plus its BLA table.
public final class ReferenceOrbit: @unchecked Sendable {
    public let family: FractalFamily
    public let power: Int
    public let center: PlanePoint
    public let precision: Int

    private let lock = NSLock()
    private var zfBuffer: MTLBuffer
    private var zxBuffer: MTLBuffer
    private var capacity: Int
    private let job: OpaquePointer
    private var computedCount = 0
    private var didEscape = false
    private var computing = false
    private let cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let progressPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private(set) var requested = 0

    /// Table matching the current point count; touched only by the thread that encodes GPU work.
    var bla: BLATable?

    init(formula: Formula, center: PlanePoint, precision: Int, capacity: Int) {
        family = formula.family
        power = formula.effectivePower
        self.center = center.withPrecision(precision)
        self.precision = precision
        self.capacity = max(capacity, 1024)
        let device = GPU.shared.device
        zfBuffer = device.makeBuffer(length: self.capacity * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
        zxBuffer = device.makeBuffer(length: self.capacity * MemoryLayout<FSRefExt>.stride, options: .storageModeShared)!
        job = fs_ref_new(family.formulaID, Int32(power), 0, self.center.re.ptr, self.center.im.ptr,
                         nil, nil, nil, nil, precision)
        cancelFlag.pointee = 0
        progressPtr.pointee = 0
    }

    deinit {
        fs_ref_free(job)
        cancelFlag.deallocate()
        progressPtr.deallocate()
    }

    struct Snapshot {
        var zf: MTLBuffer
        var zx: MTLBuffer
        var count: Int
        var escaped: Bool
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(zf: zfBuffer, zx: zxBuffer, count: computedCount, escaped: didEscape)
    }

    var isComputing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return computing
    }

    /// Points computed so far, including those not yet published.
    var progressCount: Int { progressPtr.pointee }

    func covers(_ length: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didEscape || computedCount >= length
    }

    func cancel() { cancelFlag.pointee = 1 }

    /// Computes points until `length` exist or the orbit escapes. Blocks; call off the main thread.
    func extend(to length: Int) {
        lock.lock()
        if didEscape || computedCount >= length || computing {
            lock.unlock()
            return
        }
        computing = true
        requested = length
        if length > capacity {
            let newCap = max(length, capacity * 2)
            let device = GPU.shared.device
            let nf = device.makeBuffer(length: newCap * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
            let nx = device.makeBuffer(length: newCap * MemoryLayout<FSRefExt>.stride, options: .storageModeShared)!
            memcpy(nf.contents(), zfBuffer.contents(), computedCount * MemoryLayout<SIMD2<Float>>.stride)
            memcpy(nx.contents(), zxBuffer.contents(), computedCount * MemoryLayout<FSRefExt>.stride)
            zfBuffer = nf
            zxBuffer = nx
            capacity = newCap
        }
        let zf = zfBuffer.contents().assumingMemoryBound(to: simd_float2.self)
        let zx = zxBuffer.contents().assumingMemoryBound(to: FSRefExt.self)
        lock.unlock()

        let n = fs_ref_run(job, length, zf, zx, 256.0 * 256.0, cancelFlag, progressPtr)

        lock.lock()
        computedCount = n
        didEscape = fs_ref_escaped(job) != 0
        computing = false
        lock.unlock()
    }
}

/// Picks, computes and caches reference orbits for perturbation rendering.
public final class ReferenceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ReferenceOrbit?
    private var pending: ReferenceOrbit?
    private let queue = DispatchQueue(label: "fractal.reference", qos: .userInitiated)

    /// Called on the main queue whenever a background computation finishes.
    public var onUpdate: (@Sendable () -> Void)?

    public init() {}

    public struct Status: Sendable {
        public var computing: Bool
        public var progress: Double
        public var points: Int
    }

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        for r in [pending, current].compactMap({ $0 }) where r.isComputing {
            let p = r.progressCount
            return Status(computing: true, progress: r.requested > 0 ? Double(p) / Double(r.requested) : 0, points: p)
        }
        return Status(computing: false, progress: 1, points: current?.snapshot.count ?? 0)
    }

    private func suits(_ r: ReferenceOrbit, _ formula: Formula, _ view: Viewport, need: Int, slack: Double) -> Bool {
        guard r.family == formula.family, r.power == formula.effectivePower, r.precision >= need else { return false }
        return view.center.minus(r.center).log2Abs <= view.log2Radius + slack
    }

    /// Returns a reference usable for `view`, starting background work when a better one is needed.
    /// With `blocking`, waits until an ideal reference is complete.
    func reference(formula: Formula, view: Viewport, minSide: Double, length: Int, focus: Focus? = nil,
                   blocking: Bool) -> ReferenceOrbit? {
        let need = view.requiredPrecision(minSide: minSide)
        // A new orbit anchored at the focus gets the precision of the destination, so it serves the whole motion.
        var focusView = view
        if let f = focus { focusView.log2Radius = min(f.log2Radius, view.log2Radius) }
        let newPrecision = max(need, focusView.requiredPrecision(minSide: minSide)) + 64
        lock.lock()
        if let p = pending, !p.isComputing, p.covers(length) || p.snapshot.escaped {
            if suits(p, formula, view, need: need, slack: 10) {
                current = p
                pending = nil
            }
        }
        var chosen: ReferenceOrbit?
        var start: ReferenceOrbit?
        if let cur = current, suits(cur, formula, view, need: need, slack: 3) {
            chosen = cur
            if !cur.covers(length) && !cur.isComputing { start = cur }
        } else {
            if let p = pending, suits(p, formula, view, need: need, slack: 3) {
                if !p.covers(length) && !p.isComputing { start = p }
            } else {
                pending?.cancel()
                let anchor = focus?.point ?? view.center
                let ref = ReferenceOrbit(formula: formula, center: anchor, precision: newPrecision, capacity: length + 1)
                pending = ref
                start = ref
            }
            if let cur = current, suits(cur, formula, view, need: need, slack: 10) { chosen = cur }
        }
        lock.unlock()

        if let s = start {
            if blocking {
                s.extend(to: length)
            } else {
                queue.async { [weak self] in
                    s.extend(to: length)
                    DispatchQueue.main.async { self?.onUpdate?() }
                }
            }
        }
        if blocking {
            lock.lock()
            if let p = pending, p === start || (p.covers(length) && suits(p, formula, view, need: need, slack: 10)) {
                current = p
                pending = nil
            }
            let r = current
            lock.unlock()
            if let r, suits(r, formula, view, need: need, slack: 10) { return r }
            return nil
        }
        return chosen
    }

    /// Drops all references (e.g. when memory matters or the formula changed).
    public func reset() {
        lock.lock()
        pending?.cancel()
        pending = nil
        current = nil
        lock.unlock()
    }
}

/// Bilinear-approximation table for one reference orbit, built on the GPU.
final class BLATable {
    let entries: MTLBuffer
    let r2: MTLBuffer
    let logR: MTLBuffer
    /// log2 of the smallest |Z| each approximation steps over.
    let minZ: MTLBuffer
    let offsets: [UInt32]
    let counts: [UInt32]
    let log2C: Double
    let log2Eps: Double
    let refCount: Int

    init?(encodingInto enc: MTLComputeCommandEncoder, snapshot s: ReferenceOrbit.Snapshot, formula: Formula,
          log2C: Double, log2Eps: Double) {
        let count0 = s.count - 2
        guard count0 >= 1 else { return nil }
        var offsets: [UInt32] = []
        var counts: [UInt32] = []
        var total = 0
        var c = count0
        while c >= 1 && offsets.count < Int(FS_MAX_BLA_LEVELS) {
            offsets.append(UInt32(total))
            counts.append(UInt32(c))
            total += c
            if c < 2 { break }
            c /= 2
        }
        self.offsets = offsets
        self.counts = counts
        self.log2C = log2C
        self.log2Eps = log2Eps
        refCount = s.count
        // Fresh buffers each build: in-flight passes may still read the previous table.
        let device = GPU.shared.device
        entries = device.makeBuffer(length: total * MemoryLayout<FSBLAEntry>.stride, options: .storageModePrivate)!
        r2 = device.makeBuffer(length: total * 4, options: .storageModePrivate)!
        logR = device.makeBuffer(length: total * 4, options: .storageModePrivate)!
        minZ = device.makeBuffer(length: total * 4, options: .storageModePrivate)!

        let gpu = GPU.shared
        var key = GPU.PipelineKey(name: "bla_init")
        key.formula = formula.family.formulaID
        key.power = Int32(formula.effectivePower)
        let initPSO = gpu.pipeline(key)
        key.name = "bla_merge"
        let mergePSO = gpu.pipeline(key)
        enc.setBuffer(entries, offset: 0, index: 0)
        enc.setBuffer(r2, offset: 0, index: 1)
        enc.setBuffer(logR, offset: 0, index: 2)
        enc.setBuffer(s.zx, offset: 0, index: 3)
        enc.setBuffer(minZ, offset: 0, index: 5)
        var p = FSBLABuildParams(count: UInt32(count0), srcOffset: 0, dstOffset: 0, srcCount: 0,
                                 log2Eps: Float(log2Eps), log2C: Float(max(log2C, -1e30)), pad0: 0, pad1: 0)
        enc.setBytes(&p, length: MemoryLayout<FSBLABuildParams>.stride, index: 4)
        gpu.dispatch1D(enc, initPSO, count: count0)
        for k in 1..<offsets.count {
            p.count = counts[k]
            p.srcOffset = offsets[k - 1]
            p.srcCount = counts[k - 1]
            p.dstOffset = offsets[k]
            enc.setBytes(&p, length: MemoryLayout<FSBLABuildParams>.stride, index: 4)
            gpu.dispatch1D(enc, mergePSO, count: Int(counts[k]))
        }
    }
}
