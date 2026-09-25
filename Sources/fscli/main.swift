import Foundation
import FractalKit

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

func makeScene() -> Scene {
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
    return Scene(formula: formula, view: view, iter: iter)
}

func size() -> (Int, Int) {
    let s = args.string("size", "1280x800").split(separator: "x").compactMap { Int($0) }
    return s.count == 2 ? (s[0], s[1]) : (1280, 800)
}

let engine = Engine()

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
    _ = engine.iterationMap(scene: scene, width: w, height: h)   // warm-up: pipelines, reference, BLA
    let runs = args.int("runs", 5)
    var best = Double.infinity
    for _ in 0..<runs {
        let t0 = Date()
        _ = engine.iterationMap(scene: scene, width: w, height: h)
        best = min(best, Date().timeIntervalSince(t0))
    }
    print(String(format: "%dx%d maxIter %d: best %.2f ms", w, h, scene.iter.maxIter, best * 1000))

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

default:
    print("usage: fscli render|verify|bench [--formula f] [--re x --im y] [--zoom log10] [--iter n] [--size WxH]")
}
