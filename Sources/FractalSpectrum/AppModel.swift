import AppKit
import SwiftUI
import Observation
import FractalKit

/// Rendering quality presets: anti-aliasing samples accumulated while the view rests.
enum Quality: String, CaseIterable, Identifiable {
    case fast = "Fast", balanced = "Balanced", high = "High", ultra = "Ultra"
    var id: String { rawValue }
    var samples: Int {
        switch self {
        case .fast: return 1
        case .balanced: return 4
        case .high: return 16
        case .ultra: return 64
        }
    }
}

/// App-wide state shared by the SwiftUI chrome and the Metal renderer.
@MainActor @Observable
final class AppModel {
    let engine = Engine()
    let camera: Camera
    @ObservationIgnored let renderer: LiveRenderer

    var formula = Formula() { didSet { formulaChanged(from: oldValue) } }
    var color = ColorSettings() { didSet { renderer.color = color } }
    var iter = IterationSettings() { didSet { renderer.iter = iter } }
    var quality = Quality.high { didSet { renderer.aaSamples = quality.samples } }
    var showUI = true
    var showHelp = false
    var showExport = false
    let export = ExportController()
    var autopilot = false { didSet { if autopilot { camera.cancelFlight() } } }
    var autopilotSpeed = 1.0     // zoom doublings per second
    var cycleColors = false
    var cycleSpeed = 0.08

    // HUD
    var status: LiveRenderer.Status?
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var fade: (from: Int, to: Int, t: Double)?
    @ObservationIgnored private var lastTick = CACurrentMediaTime()
    @ObservationIgnored private var devHooks: DevHooks?

    init() {
        let f = Formula()
        camera = Camera(view: Viewport.home(for: f))
        renderer = LiveRenderer(engine: engine, camera: camera)
        renderer.formula = f
        renderer.iter = iter
        renderer.color = color
        renderer.aaSamples = quality.samples
        renderer.onStatus = { [weak self] s in MainActor.assumeIsolated { self?.status = s } }
        renderer.onIterationProposal = { [weak self] n in MainActor.assumeIsolated { self?.iter.maxIter = n } }
        engine.references.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.renderer.invalidate() }
        }
        renderer.onFrame = { [weak self] dt in MainActor.assumeIsolated { self?.tick(dt) } }
        GPU.shared.prewarm()
        devHooks = DevHooks(model: self)
    }

    // MARK: Actions

    func userInteracted() {
        if autopilot && camera.isFlying { autopilot = false }
    }

    func goHome() {
        autopilot = false
        camera.fly(to: Viewport.home(for: formula), duration: 1.4)
    }

    func fly(to location: Location) {
        autopilot = false
        if location.formula != formula {
            formula = location.formula
            camera.jump(to: Viewport.home(for: formula))
        }
        if let p = location.palette { setPalette(p) }
        if let n = location.maxIter { iter.maxIter = max(iter.maxIter, n) }
        guard let v = location.viewport else { return }
        renderer.snapColors = true
        camera.fly(to: v)
        show("\(location.name)")
    }

    func zoomStep(_ log2Factor: Double) {
        let s = renderer.drawableSizeForPicking
        camera.zoom(log2Factor: log2Factor, at: SIMD2(Double(s.x), Double(s.y)) * 0.5, width: s.x, height: s.y, animated: true)
    }

    func selectFamily(_ family: FractalFamily, power: Int? = nil) {
        var f = formula
        f.family = family
        if let power { f.power = power }
        f.julia = false
        guard f != formula else { return }
        formula = f
        renderer.snapColors = true
        camera.jump(to: Viewport.home(for: f))
    }

    func toggleJulia() {
        var f = formula
        f.julia.toggle()
        if f.julia {
            // Julia parameter from the current view centre (Mandelbrot family), otherwise keep.
            let c = camera.view.center
            f.juliaRe = c.re.doubleValue
            f.juliaIm = c.im.doubleValue
        }
        formula = f
        camera.jump(to: Viewport.home(for: f))
        renderer.snapColors = true
        show(f.julia ? "Julia set for c = \(String(format: "%.5f %+.5fi", f.juliaRe, f.juliaIm))" : "Mandelbrot set")
    }

    func pickJulia(atPixel p: SIMD2<Double>) {
        let s = renderer.drawableSizeForPicking
        let c = camera.view.point(atPixel: p, width: s.x, height: s.y, flipY: formula.family.flipY)
        var f = formula
        f.julia = true
        f.juliaRe = c.re.doubleValue
        f.juliaIm = c.im.doubleValue
        formula = f
        camera.jump(to: Viewport.home(for: f))
        renderer.snapColors = true
        show("Julia set for c = \(String(format: "%.5f %+.5fi", f.juliaRe, f.juliaIm))")
    }

    func setPalette(_ i: Int) {
        let n = Palette.all.count
        let to = ((i % n) + n) % n
        guard to != color.palette else { return }
        fade = (color.palette, to, 0)
        color.palette = to
    }

    func cyclePalette(_ d: Int) {
        setPalette(color.palette + d)
        show(Palette.all[color.palette].name)
    }

    func scaleIterations(_ k: Double) {
        iter.autoIterations = false
        iter.maxIter = max(64, min(100_000_000, Int(Double(iter.maxIter) * k)))
        show("Iterations \(iter.maxIter.formatted())")
    }

    func toggleLighting() {
        color.lightStrength = color.lightStrength > 0 ? 0 : 0.75
        show(color.lightStrength > 0 ? "Lighting on" : "Lighting off")
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func copyCoordinates() {
        let v = camera.view
        let digits = Int(v.zoomLog10) + 10
        let text = "re: \(v.center.re.string(digits: digits))\nim: \(v.center.im.string(digits: digits))\nzoom: \(v.zoomText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Coordinates copied")
    }

    // MARK: Per-frame

    private func tick(_ dt: Double) {
        if var f = fade {
            f.t += dt / 0.45
            if f.t >= 1 {
                fade = nil
                renderer.paletteBlend = nil
                renderer.recolor()
            } else {
                fade = f
                let e = Float(f.t * f.t * (3 - 2 * f.t))
                renderer.paletteBlend = Engine.PaletteBlend(from: f.from, to: f.to, mix: e)
            }
        }
        if cycleColors {
            color.offset = (color.offset + dt * cycleSpeed).truncatingRemainder(dividingBy: 1)
        }
        if autopilot {
            let s = renderer.drawableSizeForPicking
            let c = SIMD2(Double(s.x), Double(s.y)) * 0.5
            camera.zoom(log2Factor: -autopilotSpeed * dt, at: c, width: s.x, height: s.y, animated: false)
            if camera.view.log2Radius <= camera.minLog2Radius + 0.01 { autopilot = false }
        }
    }

    private func formulaChanged(from old: Formula) {
        renderer.formula = formula
        camera.minLog2Radius = formula.minLog2Radius
        if formula.family != old.family || formula.effectivePower != old.effectivePower || formula.julia != old.julia {
            engine.references.reset()
            iter.maxIter = IterationSettings().maxIter
        }
    }
}
