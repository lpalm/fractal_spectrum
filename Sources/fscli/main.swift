// Headless companion of the app: renders stills and zoom videos, verifies GPU results against a
// full-precision CPU iteration, benchmarks, and locates minibrots.
import Foundation
import AVFoundation
import CoreGraphics
import CFractal
import FractalKit

/// A command followed by `--name value` options and `--name` switches.
struct Arguments {
    var command = "render"
    var values: [String: String] = [:]

    init() {
        var rest = CommandLine.arguments.dropFirst()
        if let first = rest.first, !first.hasPrefix("--") { command = rest.removeFirst() }
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("--") else { continue }
            // a switch is followed by the next option or by nothing
            let hasValue = rest.first.map { !$0.hasPrefix("--") } ?? false
            values[String(argument.dropFirst(2))] = hasValue ? rest.removeFirst() : ""
        }
    }

    func string(_ name: String, _ fallback: String) -> String { values[name] ?? fallback }
    func int(_ name: String, _ fallback: Int) -> Int { values[name].flatMap { Int($0) } ?? fallback }
    func double(_ name: String, _ fallback: Double) -> Double { values[name].flatMap { Double($0) } ?? fallback }
    func has(_ name: String) -> Bool { values[name] != nil }
}

let arguments = Arguments()
let engine = Engine()
Engine.traceTuning = arguments.has("trace")

/// The scene the options describe: --formula, --power, --julia re,im, --re, --im, --zoom (log10 of
/// the magnification), --rot (degrees), --iter, --fixed, --eps, --noder, --nobla.
func makeScene() -> FractalScene {
    var formula = Formula()
    formula.family = FractalFamily(rawValue: arguments.string("formula", "mandelbrot")) ?? .mandelbrot
    formula.power = arguments.int("power", 2)
    formula.julia = arguments.has("julia")
    let julia = arguments.string("julia", "").split(separator: ",").compactMap { Double($0) }
    if julia.count == 2 { (formula.juliaRe, formula.juliaIm) = (julia[0], julia[1]) }
    var view = Viewport.home(for: formula)
    if let zoom = arguments.values["zoom"].flatMap(Double.init) { view.log2Radius = Viewport.log2Radius(zoomLog10: zoom) }
    let precision = max(64, Int(1 - view.log2Radius) + 96)
    if let re = arguments.values["re"], let im = arguments.values["im"],
       let center = PlanePoint(re: re, im: im, precision: precision) {
        view.center = center
    } else {
        view.center = view.center.withPrecision(precision)
    }
    view.rotation = arguments.double("rot", 0) * .pi / 180
    var iteration = IterationSettings()
    iteration.maxIter = arguments.int("iter", 2000)
    iteration.autoIterations = !arguments.has("fixed")
    iteration.blaLog2Eps = arguments.double("eps", -24)
    iteration.derivative = !arguments.has("noder")
    iteration.useBLA = !arguments.has("nobla")
    return FractalScene(formula: formula, view: view, iteration: iteration)
}

/// --size WxH.
func imageSize() -> (width: Int, height: Int) {
    let size = arguments.string("size", "1280x800").split(separator: "x").compactMap { Int($0) }
    return size.count == 2 ? (size[0], size[1]) : (1280, 800)
}

/// The colours the options describe: --palette, --density, --mapping, --light, --edge, --offset.
func makeColor() -> ColorSettings {
    var color = ColorSettings()
    color.palette = arguments.int("palette", 0)
    color.density = arguments.double("density", color.density)
    color.mapping = arguments.int("mapping", color.mapping)
    color.lightStrength = arguments.double("light", color.lightStrength)
    color.edgeStrength = arguments.double("edge", color.edgeStrength)
    color.offset = arguments.double("offset", color.offset)
    return color
}

func render() throws {
    var scene = makeScene()
    let (width, height) = imageSize()
    let calibrationStart = Date()
    engine.calibrate(scene: &scene, width: width, height: height)
    print(String(format: "calibrated maxIter %d in %.3fs", scene.iteration.maxIter, Date().timeIntervalSince(calibrationStart)))
    scene.iteration.autoIterations = false
    let start = Date()
    guard let image = engine.renderStill(scene: scene, color: makeColor(),
                                         options: .init(width: width, height: height, samples: arguments.int("samples", 4)))
    else {
        print("render failed")
        exit(1)
    }
    let output = URL(fileURLWithPath: arguments.string("out", "out.png"))
    try Engine.writePNG(image, to: output)
    print(String(format: "rendered %dx%d in %.3fs -> %@", width, height, Date().timeIntervalSince(start), output.path))
}

/// Compares GPU escape iterations with a full-precision CPU iteration of every sample.
func verify() {
    var scene = makeScene()
    scene.iteration.autoIterations = false
    let (width, height) = (arguments.int("w", 48), arguments.int("h", 32))
    guard let map = engine.iterationMap(scene: scene, width: width, height: height) else { exit(1) }
    let maxIter = map.plan.effectiveMaxIter
    var exact = 0, close = 0, off = 0, interiorMismatch = 0, worst = 0
    for y in 0..<height {
        for x in 0..<width {
            let point = Engine.samplePoint(scene: scene, width: width, height: height, x: x, y: y)
            let cpu = Engine.oracle(formula: scene.formula, point: point, maxIter: maxIter, bailout: scene.iteration.bailout).n
            let n = map.iterations[y * width + x]
            let gpu = n == FS_INTERIOR ? maxIter : Int(n)
            let difference = abs(gpu - cpu)
            if difference > 2 && off < arguments.int("dump", 0) {
                print("  (\(x),\(y)) gpu \(n == FS_INTERIOR ? "inside" : String(n)) cpu \(cpu)  c=\(point.re.string(digits: 20)), \(point.im.string(digits: 20))")
            }
            if difference == 0 {
                exact += 1
            } else if difference <= 2 {
                close += 1
            } else {
                off += 1
                worst = max(worst, difference)
                if (n == FS_INTERIOR) != (cpu >= maxIter) { interiorMismatch += 1 }
            }
        }
    }
    let total = Double(width * height)
    let escaped = map.iterations.filter { $0 != FS_INTERIOR }
    print("escaped \(escaped.count)/\(width * height) range \(escaped.min() ?? 0)...\(escaped.max() ?? 0)", terminator: "  ")
    print(String(format: "perturbed=%@ deep=%@ bla=%@ maxIter=%d  exact %.1f%%  within2 %.1f%%  off %.1f%% (interior mismatch %d, worst %d)",
                 "\(map.plan.perturbed)", "\(map.plan.deep)", "\(map.plan.usesBLA)", maxIter,
                 100 * Double(exact) / total, 100 * Double(close) / total, 100 * Double(off) / total,
                 interiorMismatch, worst))
}

func bench() {
    var scene = makeScene()
    let (width, height) = imageSize()
    engine.calibrate(scene: &scene, width: width, height: height)
    let ms = engine.benchmarkPass(scene: scene, width: width, height: height, runs: arguments.int("runs", 5),
                                  warmup: arguments.double("warmup", 2), interior: !arguments.has("nointerior"))
    print(String(format: "%dx%d maxIter %d: best %.2f ms GPU", width, height, scene.iteration.maxIter, ms))
}

/// Follows the boundary: repeatedly re-centres on a high-iteration escaped sample and zooms in.
func dive() {
    var scene = makeScene()
    let target = arguments.double("to", 100)
    let stepLog10 = arguments.double("step", 2.5)
    var seed = UInt64(arguments.int("seed", 1))
    func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    let gridSide = 64
    while scene.view.zoomLog10 < target {
        engine.calibrate(scene: &scene, width: gridSide, height: gridSide)
        guard let map = engine.iterationMap(scene: scene, width: gridSide, height: gridSide) else { break }
        var candidates: [(x: Int, y: Int, iterations: UInt32)] = []
        for y in 8..<(gridSide - 8) {
            for x in 8..<(gridSide - 8) where map.iterations[y * gridSide + x] != FS_INTERIOR {
                candidates.append((x, y, map.iterations[y * gridSide + x]))
            }
        }
        if candidates.isEmpty {
            print("no escaped samples; stopping")
            break
        }
        candidates.sort { $0.iterations > $1.iterations }
        let pick = candidates[Int(random() * Double(max(1, candidates.count / 20)))]
        let point = Engine.samplePoint(scene: scene, width: gridSide, height: gridSide, x: pick.x, y: pick.y)
        let log2Radius = scene.view.log2Radius - stepLog10 / log10(2.0)   // stepLog10 decades deeper
        scene.view.center = point.withPrecision(max(64, Int(1 - log2Radius) + 96))
        scene.view.log2Radius = log2Radius
        print(String(format: "zoom 1e%.1f  maxIter %d  iter %d", scene.view.zoomLog10, scene.iteration.maxIter, pick.iterations))
    }
    let digits = Int(scene.view.zoomLog10) + 12
    print("--re \(scene.view.center.re.string(digits: digits)) --im \(scene.view.center.im.string(digits: digits)) --zoom \(scene.view.zoomLog10)")
}

/// Iteration statistics of one pass at a fixed iteration limit.
func stats() {
    let scene = makeScene()
    let (width, height) = (arguments.int("w", 64), arguments.int("h", 40))
    guard let pass = engine.runPass(scene: scene, width: width, height: height,
                                    into: engine.makeGBuffer(samples: width * height)) else { exit(1) }
    let s = engine.readStats(pass.slot)
    print(String(format: "maxIter %d (eff %d): escaped %u late %u unresolved %u interior %u  escape range %u...%u  gpu %.1f ms  mean iterations %.0f",
                 scene.iteration.maxIter, pass.plan.effectiveMaxIter, s.escaped, s.lateEscaped, s.unresolved, s.interior,
                 s.lowestEscape, s.highestEscape, pass.gpuMs, Double(s.iterations) / Double(width * height)))
}

func video() throws {
    let scene = makeScene()
    let (width, height) = imageSize()
    var color = ColorSettings()
    color.palette = arguments.int("palette", 0)
    let job = Exporter.VideoJob(formula: scene.formula, target: scene.view, start: Viewport.home(for: scene.formula),
                                color: color, width: width, height: height, fps: arguments.int("fps", 30),
                                duration: arguments.double("duration", 10), samples: arguments.int("samples", 2),
                                codec: arguments.has("prores") ? .prores : .hevc, spin: arguments.double("spin", 0))
    let output = URL(fileURLWithPath: arguments.string("out", "zoom.mp4"))
    let start = Date()
    var reported = 0.0
    try Exporter().exportVideo(job, to: output) { progress, _ in
        if progress - reported >= 0.1 || progress >= 1 {
            reported = progress
            print(String(format: "  %3.0f%%  %.1fs", progress * 100, Date().timeIntervalSince(start)))
        }
        return true
    }
    print(String(format: "video %d frames in %.1fs -> %@", job.frameCount, Date().timeIntervalSince(start), output.path))
}

/// Extracts frames at the given fractions (--at) of a video (--in) as PNGs.
func extractFrames() {
    let asset = AVURLAsset(url: URL(fileURLWithPath: arguments.string("in", "zoom.mp4")))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let done = DispatchSemaphore(value: 0)
    Task {
        let duration = (try? await asset.load(.duration)) ?? .zero
        for (i, fraction) in arguments.string("at", "0,0.5,1").split(separator: ",").compactMap({ Double($0) }).enumerated() {
            let time = CMTimeMultiplyByFloat64(duration, multiplier: min(fraction, 0.999))
            if let image = try? await generator.image(at: time).image {
                let output = URL(fileURLWithPath: arguments.string("out", "frame") + "_\(i).png")
                try? Engine.writePNG(image, to: output)
                print("wrote", output.path)
            }
        }
        done.signal()
    }
    done.wait()
}

/// Side-by-side iteration images: GPU (left) and full-precision CPU (right), log-scaled greyscale.
func compare() throws {
    var scene = makeScene()
    scene.iteration.autoIterations = false
    let (width, height) = (arguments.int("w", 160), arguments.int("h", 100))
    guard let map = engine.iterationMap(scene: scene, width: width, height: height) else { exit(1) }
    let maxIter = Double(map.plan.effectiveMaxIter)
    var cpu = [Int](repeating: 0, count: width * height)
    DispatchQueue.concurrentPerform(iterations: height) { y in
        for x in 0..<width {
            let point = Engine.samplePoint(scene: scene, width: width, height: height, x: x, y: y)
            cpu[y * width + x] = Engine.oracle(formula: scene.formula, point: point, maxIter: map.plan.effectiveMaxIter,
                                               bailout: scene.iteration.bailout).n
        }
    }
    var pixels = [UInt8](repeating: 255, count: width * 2 * height * 4)
    func put(_ x: Int, _ y: Int, _ n: Double) {
        let grey = n >= maxIter ? 0 : UInt8(max(0, min(255, 40 + 215 * log(1 + n) / log(1 + maxIter))))
        let i = (y * width * 2 + x) * 4
        pixels[i] = grey
        pixels[i + 1] = grey
        pixels[i + 2] = grey
    }
    for y in 0..<height {
        for x in 0..<width {
            let n = map.iterations[y * width + x]
            put(x, y, n == FS_INTERIOR ? maxIter : Double(n))
            put(x + width, y, Double(cpu[y * width + x]))
        }
    }
    let context = CGContext(data: &pixels, width: width * 2, height: height, bitsPerComponent: 8, bytesPerRow: width * 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    try Engine.writePNG(context.makeImage()!, to: URL(fileURLWithPath: arguments.string("out", "compare.png")))
    print("wrote compare image")
}

/// Finds the lowest-period minibrot in the view and prints its location, size and suggested views.
func minibrot() {
    let view = makeScene().view
    let start = Date()
    guard let found = Minibrot.locate(near: view.center, searchLog2Radius: view.log2Radius, viewLog2Radius: view.log2Radius,
                                      maxPeriod: arguments.int("maxperiod", 2_000_000)) else {
        print("no minibrot found")
        exit(1)
    }
    let log2Distance = found.nucleus.minus(view.center).log2Abs - view.log2Radius
    let digits = Int(-found.log2Size * log10(2.0)) + 12
    print(String(format: "period %d %@, size 2^%.1f (1e%.1f), angle %.1f°, offset %.2f radii, %.2fs", found.period,
                 found.cardioid ? "cardioid" : "disc", found.log2Size, found.log2Size * log10(2.0),
                 found.angle * 180 / .pi, exp2(log2Distance), Date().timeIntervalSince(start)))
    print("--re \(found.nucleus.re.string(digits: digits)) --im \(found.nucleus.im.string(digits: digits))")
    print(String(format: "minibrot view --zoom %.2f ; embedded julia --zoom %.2f",
                 Viewport.zoomLog10(log2Radius: found.log2Size + log2(3.0)),
                 Viewport.zoomLog10(log2Radius: (found.log2Size + view.log2Radius) / 2)))
}

/// Samples a flight from the overview to the view, checking that both ends stay exact.
func flightTest() {
    let start = Viewport.home(for: Formula())
    let end = makeScene().view
    let flight = Flight(from: start, to: end)
    print(String(format: "path %.1f duration %.1fs", flight.pathLength, flight.duration))
    for t in [0.0, 0.001, 0.1, 0.3, 0.5, 0.7, 0.9, 0.999, 1.0] {
        let view = flight.view(at: t)
        let fromEnd = view.center.minus(end.center).log2Abs - view.log2Radius
        let fromStart = view.center.minus(start.center).log2Abs - view.log2Radius
        print(String(format: "t %.3f  zoom 1e%.2f  log2(|c-end|/r) %.2f  log2(|c-start|/r) %.2f", t, view.zoomLog10,
                     fromEnd, fromStart))
    }
}

switch arguments.command {
case "render": try render()
case "verify": verify()
case "bench": bench()
case "dive": dive()
case "stats": stats()
case "video": try video()
case "frames": extractFrames()
case "compare": try compare()
case "minibrot": minibrot()
case "flighttest": flightTest()
default:
    print("usage: fscli render|verify|bench|dive|stats|video|frames|compare|minibrot|flighttest [--formula f] [--re x --im y] [--zoom log10] [--iter n] [--size WxH]")
}
