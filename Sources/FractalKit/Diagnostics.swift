import Foundation
import Metal
import CFractal

/// Verification against the full-precision CPU iteration, and GPU benchmarks (used by fscli).
extension Engine {
    /// Raw escape iterations and smooth fractions of every sample, for verification against the oracle.
    public func iterationMap(scene: FractalScene, width: Int, height: Int)
        -> (iterations: [UInt32], smoothFractions: [Float], plan: Plan)? {
        let gBuffer = gpu.device.makeBuffer(length: width * height * Engine.gBufferSampleStride, options: .storageModeShared)!
        guard let pass = runPass(scene: scene, width: width, height: height, into: gBuffer) else { return nil }
        let words = gBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let wordsPerSample = Engine.gBufferSampleStride / 4
        let samples = 0..<(width * height)
        return (samples.map { words[$0 * wordsPerSample] },
                samples.map { Float(bitPattern: words[$0 * wordsPerSample + 1]) }, pass.plan)
    }

    /// GPU milliseconds of one full iteration pass (best of `runs`) after keeping the GPU busy
    /// for `warmup` seconds so clocks have ramped up.
    public func benchmarkPass(scene: FractalScene, width: Int, height: Int, runs: Int, warmup: Double = 2,
                              interior: Bool = true) -> Double {
        let gBuffer = makeGBuffer(samples: width * height)
        func pass(wait: Bool = true) -> Double {
            runPass(scene: scene, width: width, height: height, into: gBuffer, interior: interior, resetStats: false,
                    wait: wait)?.gpuMs ?? .infinity
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
        let family = formula.family.formulaID, power = Int32(formula.effectivePower)
        guard let julia = formula.juliaParameter else {
            let n = withExtendedLifetime(point) {
                fs_oracle_pixel(family, power, point.re.handle, point.im.handle, nil, nil, maxIter, bailout * bailout, &frac)
            }
            return (n, frac)
        }
        let jre = HPFloat(julia.x, precision: point.precision), jim = HPFloat(julia.y, precision: point.precision)
        let n = withExtendedLifetime((point, jre, jim)) {
            fs_oracle_pixel(family, power, point.re.handle, point.im.handle, jre.handle, jim.handle, maxIter,
                            bailout * bailout, &frac)
        }
        return (n, frac)
    }
}
