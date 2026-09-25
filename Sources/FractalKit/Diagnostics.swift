import Foundation
import Metal
import CFractal

extension Engine {
    /// Raw escape iterations of every sample, for verification against the CPU oracle.
    public func iterationMap(scene: FractalScene, width: Int, height: Int) -> (n: [UInt32], frac: [Float], plan: Plan)? {
        let g = gpu.device.makeBuffer(length: width * height * 16, options: .storageModeShared)!
        guard let cb = gpu.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        let slot = nextStatsSlot()
        guard let plan = makePlan(scene: scene, grid: Grid(width: width, height: height), enc: enc, blocking: true,
                                  statsSlot: slot) else {
            enc.endEncoding()
            cb.commit()
            return nil
        }
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

    /// GPU milliseconds of one full iteration pass (best of `runs`) after keeping the GPU busy
    /// for `warmup` seconds so clocks have ramped up.
    public func benchmarkPass(scene: FractalScene, width: Int, height: Int, runs: Int, warmup: Double = 2) -> Double {
        let g = makeGBuffer(samples: width * height)
        func pass(wait: Bool = true) -> Double {
            guard let cb = gpu.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return .infinity }
            let slot = nextStatsSlot()
            guard let plan = makePlan(scene: scene, grid: Grid(width: width, height: height), enc: enc, blocking: true,
                                      statsSlot: slot) else {
                enc.endEncoding()
                cb.commit()
                return .infinity
            }
            encodeIterate(enc, plan: plan, gbuf: g, origin: .zero, size: SIMD2(UInt32(width), UInt32(height)),
                          bufOrigin: .zero, bufStride: UInt32(width))
            enc.endEncoding()
            cb.commit()
            if !wait { return 0 }
            cb.waitUntilCompleted()
            return (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        // keep several passes queued so the GPU never idles while its clocks ramp up
        let t0 = Date()
        while Date().timeIntervalSince(t0) < warmup {
            for _ in 0..<3 { _ = pass(wait: false) }
            _ = pass()
        }
        var best = Double.infinity
        for _ in 0..<runs { best = min(best, pass()) }
        return best
    }

    /// Plane coordinate of the centre of sample (x, y) on a width x height grid.
    public static func samplePoint(scene: FractalScene, width: Int, height: Int, x: Int, y: Int) -> PlanePoint {
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
        let n: Int
        if formula.julia {
            let jre = HPFloat(formula.juliaRe, precision: point.precision), jim = HPFloat(formula.juliaIm, precision: point.precision)
            n = fs_oracle_pixel(formula.family.formulaID, Int32(formula.effectivePower), point.re.ptr, point.im.ptr,
                                jre.ptr, jim.ptr, maxIter, bailout * bailout, &frac)
        } else {
            n = fs_oracle_pixel(formula.family.formulaID, Int32(formula.effectivePower), point.re.ptr, point.im.ptr,
                                nil, nil, maxIter, bailout * bailout, &frac)
        }
        return (n, frac)
    }
}
