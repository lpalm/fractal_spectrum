import AppKit
import SwiftUI
import Observation
import FractalKit
import CFractal

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

    /// Relative error tolerated by the bilinear approximation (log2); looser is faster and the
    /// difference is invisible except in chaotic dust.
    var blaLog2Eps: Double {
        switch self {
        case .fast: return -10
        case .balanced: return -14
        case .high: return -16
        case .ultra: return -24
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
    var quality = Quality.high {
        didSet {
            renderer.aaSamples = quality.samples
            iter.blaLog2Eps = quality.blaLog2Eps
        }
    }
    var showUI = true
    var showHelp = false
    var showExport = false
    let export = ExportController()
    var autopilot = false {
        didSet {
            if autopilot { camera.cancelFlight() }
            pilot.reset()
        }
    }
    @ObservationIgnored let pilot: Autopilot
    var cycleColors = false
    /// Extended dynamic range output on HDR-capable displays.
    var hdr = UserDefaults.standard.object(forKey: "hdr") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hdr, forKey: "hdr") }
    }
    /// HDR is used only where the display can show it.
    var hdrEnabled: Bool { hdr && hdrAvailable }
    var hdrAvailable: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.5 }
    }
    var cycleSpeed = 0.08

    // Places saved by the user
    var bookmarks: [Location] = []

    // Navigation history: views where the camera came to rest
    @ObservationIgnored private var history: [Location] = []
    @ObservationIgnored private var historyIndex = -1
    @ObservationIgnored private var restSince = 0.0
    @ObservationIgnored private var lastRestVersion = -1
    var showGoTo = false

    // Guided tour
    var touring = false
    var caption: Caption?
    @ObservationIgnored private var tourTask: Task<Void, Never>?

    struct Caption: Equatable {
        var title: String
        var subtitle: String
        var fact: String
    }

    // HUD
    var status: LiveRenderer.Status?
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var fade: (from: Int, to: Int, t: Double)?
    @ObservationIgnored private var devHooks: DevHooks?

    init() {
        let f = Formula()
        camera = Camera(view: Viewport.home(for: f))
        renderer = LiveRenderer(engine: engine, camera: camera)
        pilot = Autopilot(camera: camera, renderer: renderer)
        pilot.onArrival = { [weak self] p, ls in self?.announceMinibrot(period: p, log2Size: ls) }
        renderer.formula = f
        iter.blaLog2Eps = quality.blaLog2Eps
        renderer.iter = iter
        renderer.color = color
        renderer.aaSamples = quality.samples
        renderer.onStatus = { [weak self] s in MainActor.assumeIsolated { self?.status = s } }
        renderer.onIterationProposal = { [weak self] n in MainActor.assumeIsolated { self?.iter.maxIter = n } }
        engine.references.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.renderer.invalidate() }
        }
        renderer.onFrame = { [weak self] dt in MainActor.assumeIsolated { self?.tick(dt) } }
        renderer.onProbe = { [weak self] p in
            MainActor.assumeIsolated {
                guard let self, self.autopilot else { return }
                self.pilot.steer(with: p, formula: self.formula)
            }
        }
        GPU.shared.prewarm()
        devHooks = DevHooks(model: self)
        loadBookmarks()
        restoreSession()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    // MARK: Persistence

    private struct Session: Codable {
        var place: Location
        var color: ColorSettings
        var quality: String
        var autoIterations: Bool
    }

    private static let sessionKey = "session.v1"
    private static let bookmarksKey = "bookmarks.v1"
    @ObservationIgnored private var lastSavedSession: Data?

    func saveSession() {
        let place = Location(id: "session", name: "Last view", formula: formula, view: camera.view,
                             palette: color.palette, maxIter: iter.maxIter)
        let session = Session(place: place, color: color, quality: quality.rawValue, autoIterations: iter.autoIterations)
        guard let data = try? JSONEncoder().encode(session), data != lastSavedSession else { return }
        lastSavedSession = data
        UserDefaults.standard.set(data, forKey: AppModel.sessionKey)
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.sessionKey),
              let s = try? JSONDecoder().decode(Session.self, from: data), let v = s.place.viewport else { return }
        formula = s.place.formula
        color = s.color
        quality = Quality(rawValue: s.quality) ?? quality
        iter.autoIterations = s.autoIterations
        if let n = s.place.maxIter { iter.maxIter = n }
        camera.minLog2Radius = formula.minLog2Radius
        camera.jump(to: v)
        lastSavedSession = data
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.bookmarksKey),
              let list = try? JSONDecoder().decode([Location].self, from: data) else { return }
        bookmarks = list
    }

    private func storeBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: AppModel.bookmarksKey) }
    }

    func addBookmark() {
        let v = camera.view
        let name = "\(formula.displayName) · " + ScaleFact.magnification(v.zoomLog10)
        let place = Location(id: "bm-" + UUID().uuidString, name: name, formula: formula, view: v,
                             palette: color.palette, maxIter: iter.maxIter)
        bookmarks.insert(place, at: 0)
        storeBookmarks()
        show("Saved to Your Places")
    }

    func removeBookmark(_ place: Location) {
        bookmarks.removeAll { $0.id == place.id }
        storeBookmarks()
    }

    // MARK: Actions

    func userInteracted() {
        if autopilot && camera.isFlying { autopilot = false }
        if touring { stopTour() }
    }

    func startTour() {
        stopTour()
        autopilot = false
        touring = true
        tourTask = Task { @MainActor [weak self] in
            let stops = Location.tourIDs.compactMap { id in Location.all.first { $0.id == id } }
            for loc in stops {
                guard let self, self.touring, !Task.isCancelled else { return }
                self.caption = nil
                self.fly(to: loc, announce: false)
                try? await Task.sleep(for: .milliseconds(300))
                while self.camera.isFlying && self.touring && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard self.touring, !Task.isCancelled else { return }
                self.caption = Caption(title: loc.name, subtitle: "Magnified " + ScaleFact.magnification(loc.zoom),
                                       fact: ScaleFact.describe(zoomLog10: loc.zoom))
                try? await Task.sleep(for: .seconds(loc.zoom > 50 ? 7 : 5))
            }
            guard let self, self.touring else { return }
            self.caption = nil
            self.touring = false
            self.goHome()
        }
    }

    func stopTour() {
        touring = false
        tourTask?.cancel()
        tourTask = nil
        caption = nil
    }

    func goHome() {
        autopilot = false
        camera.fly(to: Viewport.home(for: formula), duration: 1.4)
    }

    func fly(to location: Location, announce: Bool = true) {
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
        if announce { show("\(location.name) · " + ScaleFact.magnification(location.zoom)) }
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

    /// Locates the lowest-period minibrot in view (quadratic Mandelbrot only) and flies to it.
    var searchingMinibrot = false

    func findMinibrot() {
        guard formula.family == .mandelbrot, formula.effectivePower == 2, !formula.julia else {
            show("Mini-Mandelbrot search works in the Mandelbrot set")
            return
        }
        guard !searchingMinibrot else { return }
        searchingMinibrot = true
        autopilot = false
        stopTour()
        show("Searching for a mini-Mandelbrot…")
        let view = camera.view
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = AppModel.locateMinibrot(in: view)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchingMinibrot = false
                guard let (target, p, ls) = found else {
                    self.show("No mini-Mandelbrot found here — try zooming closer to the edge")
                    return
                }
                self.renderer.snapColors = true
                self.camera.fly(to: target)
                self.announceMinibrot(period: p, log2Size: ls)
            }
        }
    }

    /// Minibrot (target view, period, log2 size) whose nucleus lies in or near `view`, if any.
    nonisolated private static func locateMinibrot(in view: Viewport) -> (Viewport, Int, Double)? {
        let period = Minibrot.period(center: view.center, log2Radius: view.log2Radius, maxPeriod: 2_000_000)
        guard period > 0 else { return nil }
        let prec = max(view.center.precision, Int(-view.log2Radius) * 2 + 160)
        guard let n = Minibrot.nucleus(near: view.center, period: period, precision: prec) else { return nil }
        let (ls, _, cardioid) = Minibrot.size(nucleus: n, period: period)
        guard cardioid, ls.isFinite, ls < view.log2Radius, n.minus(view.center).log2Abs < view.log2Radius + 2 else { return nil }
        return (Viewport(center: n, log2Radius: ls + log2(2.6), rotation: view.rotation), period, ls)
    }

    func announceMinibrot(period: Int, log2Size: Double) {
        show("Mini-Mandelbrot of period \(period.formatted()) · " + ScaleFact.magnification((1 - log2Size) * log10(2.0)), duration: 2.5)
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

    func show(_ message: String, duration: Double = 1.6) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// The view as text that `goTo(text:)` accepts.
    var coordinatesText: String {
        let v = camera.view
        let digits = Int(v.zoomLog10) + 10
        return "re: \(v.center.re.string(digits: digits))\nim: \(v.center.im.string(digits: digits))\nzoom: \(v.zoomText)"
    }

    func copyCoordinates() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coordinatesText, forType: .string)
        show("Coordinates copied")
    }

    // MARK: History

    /// Records the view once the camera has rested for a moment after moving.
    private func recordHistory() {
        let now = CACurrentMediaTime()
        if camera.isAnimating || touring || autopilot {
            restSince = now
            return
        }
        guard camera.version != lastRestVersion, now - restSince > 0.8 else { return }
        lastRestVersion = camera.version
        let place = Location(id: "h\(camera.version)", name: "History", formula: formula, view: camera.view,
                             palette: color.palette, maxIter: nil)
        if historyIndex >= 0, historyIndex < history.count,
           let v = history[historyIndex].viewport, abs(v.log2Radius - camera.view.log2Radius) < 0.3,
           camera.view.center.minus(v.center).log2Abs < v.log2Radius - 3 {
            return   // barely moved
        }
        history = Array(history.prefix(historyIndex + 1))
        history.append(place)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = history.count - 1
    }

    func goBack() { stepHistory(-1) }
    func goForward() { stepHistory(1) }

    private func stepHistory(_ d: Int) {
        let i = historyIndex + d
        guard i >= 0, i < history.count, let v = history[i].viewport else {
            show(d < 0 ? "Start of history" : "End of history")
            return
        }
        historyIndex = i
        let place = history[i]
        if place.formula != formula {
            formula = place.formula
            camera.jump(to: Viewport.home(for: formula))
        }
        renderer.snapColors = true
        camera.fly(to: v, duration: min(3, max(0.8, abs(v.log2Radius - camera.view.log2Radius) * 0.06)))
        lastRestVersion = -1
    }

    // MARK: Coordinates

    /// Flies to coordinates in the format produced by Copy Coordinates ("re: … im: … zoom: …"),
    /// or three whitespace/comma separated numbers (re, im, log10 zoom).
    @discardableResult
    func goTo(text: String) -> Bool {
        var re: String?, im: String?, zoom: Double?
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "re", "real", "x": re = parts[1]
            case "im", "imag", "imaginary", "y": im = parts[1]
            case "zoom", "magnification":
                let z = parts[1].replacingOccurrences(of: "×", with: "")
                if let e = z.range(of: "e", options: .caseInsensitive), let m = Double(z[..<e.lowerBound]),
                   let x = Double(z[e.upperBound...]) {
                    zoom = log10(m) + x
                } else if let v = Double(z) {
                    zoom = log10(max(v, 1e-9))
                }
            default: break
            }
        }
        if re == nil {
            let nums = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).map(String.init)
            if nums.count >= 2 { re = nums[0]; im = nums[1] }
            if nums.count >= 3 { zoom = Double(nums[2]) }
        }
        guard let r = re, let i = im else { return false }
        let z = zoom ?? camera.view.zoomLog10
        let place = Location(id: "goto", name: "Coordinates", formula: formula, re: r, im: i, zoom: z)
        guard let v = place.viewport else { return false }
        renderer.snapColors = true
        camera.fly(to: v)
        show("Flying to " + ScaleFact.magnification(z))
        return true
    }

    // MARK: Per-frame

    private func tick(_ dt: Double) {
        recordHistory()
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
        if autopilot && !pilot.step(dt: dt, flipY: formula.family.flipY) { autopilot = false }
    }

    private func formulaChanged(from old: Formula) {
        renderer.formula = formula
        camera.minLog2Radius = formula.minLog2Radius
        if formula.family != old.family || formula.effectivePower != old.effectivePower || formula.julia != old.julia {
            engine.references.reset()
            iter.maxIter = IterationSettings().maxIter
            iter.blaLog2Eps = quality.blaLog2Eps
        }
    }
}
