import Foundation
import AVFoundation
import CoreGraphics
import FractalKit

func import_frames() {
    let url = URL(fileURLWithPath: args.string("in", "zoom.mp4"))
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let sem = DispatchSemaphore(value: 0)
    Task {
        let duration = (try? await asset.load(.duration)) ?? .zero
        for (i, f) in args.string("at", "0,0.5,1").split(separator: ",").compactMap({ Double($0) }).enumerated() {
            let t = CMTimeMultiplyByFloat64(duration, multiplier: min(f, 0.999))
            if let img = try? await gen.image(at: t).image {
                let out = URL(fileURLWithPath: args.string("out", "frame") + "_\(i).png")
                try? Engine.writePNG(img, to: out)
                print("wrote", out.path)
            }
        }
        sem.signal()
    }
    sem.wait()
}

// Headless renderer: renders stills, verifies GPU results against the CPU oracle and benchmarks.

struct Args {
    var command = "render"
    var values: [String: String] = [:]

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        if let c = it.next() { command = c }
        while let a = it.next() {
            guard a.hasPrefix("--") else { continue }
            values[String(a.dropFirst(2))] = it.next() ?? ""
        }
    }

    func string(_ k: String, _ d: String) -> String { values[k] ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap { Int($0) } ?? d }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap { Double($0) } ?? d }
}

let args = Args()

func makeScene() -> FractalScene {
    var formula = Formula()
    formula.family = FractalFamily(rawValue: args.string("formula", "mandelbrot")) ?? .mandelbrot
    formula.power = args.int("power", 2)
    formula.julia = args.values["julia"] != nil
    if let j = args.values["julia"], let comma = j.firstIndex(of: ",") {
        formula.juliaRe = Double(j[..<comma]) ?? formula.juliaRe
        formula.juliaIm = Double(j[j.index(after: comma)...]) ?? formula.juliaIm
    }
    var view = Viewport.home(for: formula)
    // --zoom is log10 of the magnification
    if let z = args.values["zoom"], let l = Double(z) { view.log2Radius = 1 - l / log10(2.0) }
    let prec = max(64, Int((1 - view.log2Radius) * 1.0) + 96)
    if let re = args.values["re"], let im = args.values["im"], let p = PlanePoint(re: re, im: im, precision: prec) {
        view.center = p
    } else {
        view.center = view.center.withPrecision(prec)
    }
    view.rotation = args.double("rot", 0) * .pi / 180
    var iter = IterationSettings()
    iter.maxIter = args.int("iter", 2000)
    iter.autoIterations = args.values["fixed"] == nil
    iter.blaLog2Eps = args.double("eps", -24)
    iter.derivative = args.values["noder"] == nil
    iter.useBLA = args.values["nobla"] == nil
    return FractalScene(formula: formula, view: view, iter: iter)
}

func size() -> (Int, Int) {
    let s = args.string("size", "1280x800").split(separator: "x").compactMap { Int($0) }
    return s.count == 2 ? (s[0], s[1]) : (1280, 800)
}

let engine = Engine()
Engine.traceTuning = args.values["trace"] != nil

switch args.command {
case "render":
    var scene = makeScene()
    let (w, h) = size()
    let tc = Date()
    engine.calibrate(scene: &scene, width: w, height: h)
    print(String(format: "calibrated maxIter %d in %.3fs", scene.iter.maxIter, Date().timeIntervalSince(tc)))
    scene.iter.autoIterations = false
    var color = ColorSettings()
    color.palette = args.int("palette", 0)
    color.density = args.double("density", color.density)
    color.mapping = args.int("mapping", color.mapping)
    color.lightStrength = args.double("light", color.lightStrength)
    color.edgeStrength = args.double("edge", color.edgeStrength)
    let t0 = Date()
    guard let img = engine.renderStill(scene: scene, color: color,
                                       options: .init(width: w, height: h, samples: args.int("samples", 4))) else {
        print("render failed")
        exit(1)
    }
    let out = URL(fileURLWithPath: args.string("out", "out.png"))
    try Engine.writePNG(img, to: out)
    print(String(format: "rendered %dx%d in %.3fs -> %@", w, h, Date().timeIntervalSince(t0), out.path))

case "verify":
    // Compares GPU escape iterations with a full-precision CPU iteration of every sample.
    var scene = makeScene()
    scene.iter.autoIterations = false
    let (w, h) = (args.int("w", 48), args.int("h", 32))
    guard let map = engine.iterationMap(scene: scene, width: w, height: h) else { exit(1) }
    var exact = 0, close = 0, bad = 0, interiorMismatch = 0
    var worst = 0
    for y in 0..<h {
        for x in 0..<w {
            let p = Engine.samplePoint(scene: scene, width: w, height: h, x: x, y: y)
            let o = Engine.oracle(formula: scene.formula, point: p, maxIter: map.plan.effectiveMaxIter,
                                  bailout: scene.iter.bailout)
            let g = map.n[y * w + x]
            let gi = g == 0xFFFF_FFFF ? map.plan.effectiveMaxIter : Int(g)
            let d = abs(gi - o.n)
            if d > 2 && bad < args.int("dump", 0) {
                print("  (\(x),\(y)) gpu \(g == 0xFFFF_FFFF ? "inside" : String(g)) cpu \(o.n)  c=\(p.re.string(digits: 20)), \(p.im.string(digits: 20))")
            }
            if d == 0 { exact += 1 } else if d <= 2 { close += 1 } else {
                bad += 1
                worst = max(worst, d)
                if (g == 0xFFFF_FFFF) != (o.n >= map.plan.effectiveMaxIter) { interiorMismatch += 1 }
            }
        }
    }
    let total = w * h
    let escapedN = map.n.filter { $0 != 0xFFFF_FFFF }
    print("escaped \(escapedN.count)/\(total) range \(escapedN.min() ?? 0)...\(escapedN.max() ?? 0)", terminator: "  ")
    print(String(format: "perturbed=%@ deep=%@ bla=%@ maxIter=%d  exact %.1f%%  within2 %.1f%%  off %.1f%% (interior mismatch %d, worst %d)",
                 "\(map.plan.perturbed)", "\(map.plan.deep)", "\(map.plan.usedBLA)", map.plan.effectiveMaxIter,
                 100 * Double(exact) / Double(total), 100 * Double(close) / Double(total),
                 100 * Double(bad) / Double(total), interiorMismatch, worst))

case "bench":
    var scene = makeScene()
    let (w, h) = size()
    engine.calibrate(scene: &scene, width: w, height: h)
    let ms = engine.benchmarkPass(scene: scene, width: w, height: h, runs: args.int("runs", 5),
                                  warmup: args.double("warmup", 2))
    print(String(format: "%dx%d maxIter %d: best %.2f ms GPU", w, h, scene.iter.maxIter, ms))

case "dive":
    // Follows the boundary: repeatedly re-centres on a high-iteration escaped sample and zooms in.
    var scene = makeScene()
    let target = args.double("to", 100)
    let stepLog10 = args.double("step", 2.5)
    var seed = UInt64(args.int("seed", 1))
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    let n = 64
    while scene.view.zoomLog10 < target {
        engine.calibrate(scene: &scene, width: n, height: n)
        guard let map = engine.iterationMap(scene: scene, width: n, height: n) else { break }
        var cands: [(Int, Int, UInt32)] = []
        for y in 8..<(n - 8) { for x in 8..<(n - 8) where map.n[y * n + x] != 0xFFFF_FFFF { cands.append((x, y, map.n[y * n + x])) } }
        if cands.isEmpty { print("no escaped samples; stopping"); break }
        cands.sort { $0.2 > $1.2 }
        let pick = cands[Int(rand() * Double(max(1, cands.count / 20)))]
        let p = Engine.samplePoint(scene: scene, width: n, height: n, x: pick.0, y: pick.1)
        let newLog2R = scene.view.log2Radius - stepLog10 / log10(2.0)
        let prec = max(64, Int(1 - newLog2R) + 96)
        scene.view.center = p.withPrecision(prec)
        scene.view.log2Radius = newLog2R
        print(String(format: "zoom 1e%.1f  maxIter %d  iter %d", scene.view.zoomLog10, scene.iter.maxIter, pick.2))
    }
    print("--re \(scene.view.center.re.string(digits: Int(scene.view.zoomLog10) + 12)) --im \(scene.view.center.im.string(digits: Int(scene.view.zoomLog10) + 12)) --zoom \(scene.view.zoomLog10)")

case "stats":
    // Iteration statistics of one pass at a fixed iteration limit.
    let scene = makeScene()
    let (w, h) = (args.int("w", 64), args.int("h", 40))
    guard let cb = engine.gpu.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { exit(1) }
    let slot = engine.nextStatsSlot()
    let g = engine.makeGBuffer(samples: w * h)
    guard let plan = engine.makePlan(scene: scene, grid: .init(width: w, height: h), enc: enc, blocking: true, statsSlot: slot) else { exit(1) }
    engine.encodeStatsReset(enc, slot: slot)
    engine.encodeIterate(enc, plan: plan, gbuf: g, origin: .zero, size: SIMD2(UInt32(w), UInt32(h)), bufOrigin: .zero, bufStride: UInt32(w))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let s = engine.readStats(slot)
    print(String(format: "maxIter %d (eff %d): escaped %u late %u unresolved %u interior %u  gpu %.1f ms", scene.iter.maxIter,
                 plan.effectiveMaxIter, s.escaped, s.lateEscaped, s.unresolved, s.interior, (cb.gpuEndTime - cb.gpuStartTime) * 1000))

case "video":
    let scene = makeScene()
    let (w, h) = size()
    var color = ColorSettings()
    color.palette = args.int("palette", 0)
    let job = Exporter.VideoJob(formula: scene.formula, target: scene.view, start: Viewport.home(for: scene.formula),
                                color: color, colorStats: nil, width: w, height: h, fps: args.int("fps", 30),
                                duration: args.double("duration", 10), samples: args.int("samples", 2),
                                codec: args.values["prores"] != nil ? .prores : .hevc, spin: args.double("spin", 0))
    let out = URL(fileURLWithPath: args.string("out", "zoom.mp4"))
    let t0 = Date()
    var last = 0.0
    try Exporter().exportVideo(job, to: out) { p, _ in
        if p - last >= 0.1 || p >= 1 {
            last = p
            print(String(format: "  %3.0f%%  %.1fs", p * 100, Date().timeIntervalSince(t0)))
        }
        return true
    }
    print(String(format: "video %d frames in %.1fs -> %@", job.frameCount, Date().timeIntervalSince(t0), out.path))

case "frames":
    // Extracts frames at the given fractions of a video as PNGs.
    import_frames()

case "compare":
    // Side-by-side iteration images: GPU (left) and full-precision CPU (right), log-scaled greyscale.
    var scene = makeScene()
    scene.iter.autoIterations = false
    let (w, h) = (args.int("w", 160), args.int("h", 100))
    guard let map = engine.iterationMap(scene: scene, width: w, height: h) else { exit(1) }
    var cpu = [Int](repeating: 0, count: w * h)
    DispatchQueue.concurrentPerform(iterations: h) { y in
        for x in 0..<w {
            let p = Engine.samplePoint(scene: scene, width: w, height: h, x: x, y: y)
            cpu[y * w + x] = Engine.oracle(formula: scene.formula, point: p, maxIter: map.plan.effectiveMaxIter,
                                           bailout: scene.iter.bailout).n
        }
    }
    let maxI = Double(map.plan.effectiveMaxIter)
    var px = [UInt8](repeating: 255, count: w * 2 * h * 4)
    func put(_ x: Int, _ y: Int, _ n: Double) {
        let v = n >= maxI ? 0 : UInt8(max(0, min(255, 40 + 215 * log(1 + n) / log(1 + maxI))))
        let i = (y * w * 2 + x) * 4
        px[i] = v; px[i + 1] = v; px[i + 2] = v
    }
    for y in 0..<h {
        for x in 0..<w {
            let g = map.n[y * w + x]
            put(x, y, g == 0xFFFF_FFFF ? maxI : Double(g))
            put(x + w, y, Double(cpu[y * w + x]))
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &px, width: w * 2, height: h, bitsPerComponent: 8, bytesPerRow: w * 8, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    try Engine.writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: args.string("out", "compare.png")))
    print("wrote compare image")

case "minibrot":
    // Finds the lowest-period minibrot in the view and prints its location, size and suggested views.
    let scene = makeScene()
    let v = scene.view
    let t0 = Date()
    let p = Minibrot.period(center: v.center, log2Radius: v.log2Radius, maxPeriod: args.int("maxperiod", 2_000_000))
    guard p > 0 else { print("no period found"); exit(1) }
    let prec = max(v.center.precision, Int(-v.log2Radius) * 2 + 128)
    guard let n = Minibrot.nucleus(near: v.center, period: p, precision: prec) else { print("newton failed"); exit(1) }
    let ls = Minibrot.log2Size(nucleus: n, period: p)
    let dist = n.minus(v.center).log2Abs - v.log2Radius
    let digits = Int(-ls * 0.30103) + 12
    print(String(format: "period %d, size 2^%.1f (1e%.1f), offset %.2f radii, %.2fs", p, ls, ls * 0.30103, exp2(dist), Date().timeIntervalSince(t0)))
    print("--re \(n.re.string(digits: digits)) --im \(n.im.string(digits: digits))")
    let zMini = (1 - (ls + log2(3.0))) * log10(2.0)
    print(String(format: "minibrot view --zoom %.2f ; embedded julia --zoom %.2f", zMini, (1 - (ls + v.log2Radius) / 2) * log10(2.0)))

case "flighttest":
    let a = Viewport.home(for: Formula())
    let b = makeScene().view
    let f = Flight(from: a, to: b)
    print(String(format: "path %.1f duration %.1fs", f.pathLength, f.duration))
    for t in [0.0, 0.001, 0.1, 0.3, 0.5, 0.7, 0.9, 0.999, 1.0] {
        let v = f.view(at: t)
        let dEnd = v.center.minus(b.center).log2Abs - v.log2Radius
        let dStart = v.center.minus(a.center).log2Abs - v.log2Radius
        print(String(format: "t %.3f  zoom 1e%.2f  log2(|c-end|/r) %.2f  log2(|c-start|/r) %.2f", t, v.zoomLog10, dEnd, dStart))
    }

default:
    print("usage: fscli render|verify|bench [--formula f] [--re x --im y] [--zoom log10] [--iter n] [--size WxH]")
}
