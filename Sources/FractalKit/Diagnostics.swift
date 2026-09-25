import Foundation
import Metal
import CFractal

/// Verification and benchmarking against the CPU (used by fscli).
extension Engine {
    /// Raw escape iterations of every sample, for verification against the CPU oracle.
    public func iterationMap(scene: FractalScene, width: Int, height: Int) -> (n: [UInt32], frac: [Float], plan: Plan)? {
        let gBuffer = gpu.device.makeBuffer(length: width * height * 16, options: .storageModeShared)!
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        let slot = nextStatsSlot()
        guard let plan = makePlan(scene: scene, grid: Grid(width: width, height: height), encoder: encoder,
                                  blocking: true, statsSlot: slot) else {
            encoder.endEncoding()
            commandBuffer.commit()
            return nil
        }
        encodeStatsReset(encoder, slot: slot)
        encodeIterate(encoder, plan: plan, into: gBuffer, origin: .zero, size: SIMD2(UInt32(width), UInt32(height)),
                      bufferOrigin: .zero, bufferStride: UInt32(width))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // each sample: escape iteration, smooth fraction (float bits), distance estimate, normal
        let words = gBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let samples = 0..<(width * height)
        return (samples.map { words[$0 * 4] }, samples.map { Float(bitPattern: words[$0 * 4 + 1]) }, plan)
    }

    /// GPU milliseconds of one full iteration pass (best of `runs`) after keeping the GPU busy
    /// for `warmup` seconds so clocks have ramped up.
    public func benchmarkPass(scene: FractalScene, width: Int, height: Int, runs: Int, warmup: Double = 2,
                              interior: Bool = true) -> Double {
        let gBuffer = makeGBuffer(samples: width * height)
        func pass(wait: Bool = true) -> Double {
            guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return .infinity }
            let slot = nextStatsSlot()
            guard let plan = makePlan(scene: scene, grid: Grid(width: width, height: height), encoder: encoder,
                                      blocking: true, statsSlot: slot, interior: interior) else {
                encoder.endEncoding()
                commandBuffer.commit()
                return .infinity
            }
            encodeIterate(encoder, plan: plan, into: gBuffer, origin: .zero, size: SIMD2(UInt32(width), UInt32(height)),
                          bufferOrigin: .zero, bufferStride: UInt32(width))
            encoder.endEncoding()
            commandBuffer.commit()
            if !wait { return 0 }
            commandBuffer.waitUntilCompleted()
            return (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        }
        // keep several passes queued so the GPU never idles while its clocks ramp up
        let start = Date()
        while Date().timeIntervalSince(start) < warmup {
            for _ in 0..<3 { _ = pass(wait: false) }
            _ = pass()
        }
        return (0..<runs).map { _ in pass() }.min() ?? .infinity
    }

    /// Plane coordinate of the centre of sample (x, y) on a width x height grid, with 16 bits to
    /// spare for the oracle.
    public static func samplePoint(scene: FractalScene, width: Int, height: Int, x: Int, y: Int) -> PlanePoint {
        let view = scene.view
        let q = SIMD2(Double(x) + 0.5 - 0.5 * Double(width), Double(y) + 0.5 - 0.5 * Double(height))
        let delta = view.planeDelta(pixels: q, width: width, height: height, flipY: scene.formula.family.flipY)
        return view.center.offset(by: delta, precision: view.center.precision + 16)
    }

    /// Full-precision CPU iteration count of one point.
    public static func oracle(formula: Formula, point: PlanePoint, maxIter: Int, bailout: Double) -> (n: Int, frac: Double) {
        var frac = 0.0
        let n: Int
        if formula.julia {
            let jre = HPFloat(formula.juliaRe, precision: point.precision)
            let jim = HPFloat(formula.juliaIm, precision: point.precision)
            n = fs_oracle_pixel(formula.family.formulaID, Int32(formula.effectivePower), point.re.ptr, point.im.ptr,
                                jre.ptr, jim.ptr, maxIter, bailout * bailout, &frac)
        } else {
            n = fs_oracle_pixel(formula.family.formulaID, Int32(formula.effectivePower), point.re.ptr, point.im.ptr,
                                nil, nil, maxIter, bailout * bailout, &frac)
        }
        return (n, frac)
    }
}
