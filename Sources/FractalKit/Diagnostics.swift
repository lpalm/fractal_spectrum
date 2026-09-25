import Foundation
import Metal
import CFractal

extension Engine {
    /// Raw escape iterations of every sample, for verification against the CPU oracle.
    public func iterationMap(scene: Scene, width: Int, height: Int) -> (n: [UInt32], frac: [Float], plan: Plan)? {
        let g = gpu.device.makeBuffer(length: width * height * 16, options: .storageModeShared)!
        guard let cb = gpu.queue.makeCommandBuffer() else { return nil }
        let slot = nextStatsSlot()
        guard let plan = makePlan(scene: scene, grid: Grid(width: width, height: height), cb: cb, blocking: true,
                                  statsSlot: slot),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        encodeStatsReset(enc, slot: slot)
        encodeIterate(enc, plan: plan, gbuf: g, origin: .zero, size: SIMD2(UInt32(width), UInt32(height)),
                      bufOrigin: .zero, bufStride: UInt32(width))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let raw = g.contents().assumingMemoryBound(to: UInt32.self)
        var n = [UInt32](repeating: 0, count: width * height)
        var frac = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            n[i] = raw[i * 4]
            frac[i] = Float(bitPattern: raw[i * 4 + 1])
        }
        return (n, frac, plan)
    }

    /// Plane coordinate of the centre of sample (x, y) on a width x height grid.
    public static func samplePoint(scene: Scene, width: Int, height: Int, x: Int, y: Int) -> PlanePoint {
        let v = scene.view
        let log2Step = v.log2Radius + 1 - log2(Double(min(width, height)))
        let step = FloatExp.fromLog2(log2Step)
        let fy: Double = scene.formula.family.flipY ? -1 : 1
        let px = Double(x) + 0.5 - 0.5 * Double(width)
        let py = Double(y) + 0.5 - 0.5 * Double(height)
        let cs = cos(v.rotation), sn = sin(v.rotation)
        let dre = step * (px * cs + py * sn * fy)
        let dim = step * (px * sn - py * cs * fy)
        let prec = v.center.precision + 16
        return v.center.offset(by: ComplexExp(re: dre, im: dim), precision: prec)
    }

    /// Full-precision CPU iteration count of one point.
    public static func oracle(formula: Formula, point: PlanePoint, maxIter: Int, bailout: Double) -> (n: Int, frac: Double) {
        var frac = 0.0
        let n = fs_oracle_pixel(formula.family.formulaID, Int32(formula.effectivePower), point.re.ptr, point.im.ptr,
                                maxIter, bailout * bailout, &frac)
        return (n, frac)
    }
}
