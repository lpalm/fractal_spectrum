import AppKit
import SwiftUI
import Observation
import FractalKit
import CFractal

/// Rendering quality presets.
enum Quality: String, CaseIterable, Identifiable {
    case fast = "Fast", balanced = "Balanced", high = "High", ultra = "Ultra"
    var id: String { rawValue }

    /// Anti-aliasing samples accumulated while the view rests.
    var samples: Int {
        switch self {
        case .fast: 1
        case .balanced: 4
        case .high: 16
        case .ultra: 64
        }
    }

    /// Relative error tolerated by the bilinear approximation (log2); looser is faster and the
    /// difference is invisible except in chaotic dust.
    var blaLog2Eps: Double {
        switch self {
        case .fast: -10
        case .balanced: -14
        case .high: -16
        case .ultra: -24
        }
    }
}

/// App-wide state shared by the SwiftUI chrome and the Metal renderer, and the actions on it.
@MainActor @Observable
final class AppModel {
    let engine = Engine()
    let camera: Camera
    @ObservationIgnored let renderer: LiveRenderer
    @ObservationIgnored let autopilot: Autopilot
    let export = ExportController()

    var formula = Formula() { didSet { formulaChanged(from: oldValue) } }
    var color = ColorSettings() { didSet { renderer.color = color } }
    var iteration = IterationSettings() { didSet { renderer.iteration = iteration } }
    var quality = Quality.high {
        didSet {
            renderer.samplesPerPixel = quality.samples
            iteration.blaLog2Eps = quality.blaLog2Eps
        }
    }
    var autopilotEngaged = false {
        didSet {
            if autopilotEngaged { camera.cancelFlight() } else if oldValue { autopilot.coast() }
            autopilot.reset()
        }
    }
    /// Lets the palette drift slowly ("Animate colours").
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

    // Interface
    var showUI = true {
        didSet { if oldValue && !showUI { announce("Space brings the interface back") } }
    }
    var showHelp = false
    var showExport = false
    var showGoTo = false
    var status: LiveRenderer.Status?
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Julia parameter under the pointer while ⌥ is held over the Mandelbrot set.
    var juliaHover: JuliaHover?
    /// Orbit of the point under the pointer while ⇧ is held.
    var orbitHover: OrbitHover?
    /// Start of the live recording in progress (⌘R).
    var recordingSince: Date?

    /// Places saved by the user.
    var bookmarks: [Location] = []

    // Navigation history: views where the camera came to rest
    @ObservationIgnored private var history: [Location] = []
    @ObservationIgnored private var historyIndex = -1
    @ObservationIgnored private var restSince = 0.0
    @ObservationIgnored private var lastRestVersion = -1

    // Guided tour (see Tour.swift)
    var touring = false
    var caption: Caption?
    @ObservationIgnored var tourTask: Task<Void, Never>?

    /// The tour's caption for the place on screen.
    struct Caption: Equatable {
        var title: String
        var subtitle: String
        var fact: String
    }

    var searchingMinibrot = false
    @ObservationIgnored private var paletteFade: (from: Int, to: Int, progress: Double)?
    @ObservationIgnored private var devHooks: DevHooks?
    /// Palette cycles per second while `cycleColors` is on.
    private static let colorCycleSpeed = 0.08

    init() {
        let formula = Formula()
        camera = Camera(view: Viewport.home(for: formula))
        renderer = LiveRenderer(engine: engine, camera: camera)
        autopilot = Autopilot(camera: camera, renderer: renderer)
        autopilot.onArrival = { [weak self] period, log2Size in self?.announceMinibrot(period: period, log2Size: log2Size) }
        renderer.formula = formula
        iteration.blaLog2Eps = quality.blaLog2Eps
        renderer.iteration = iteration
        renderer.color = color
        renderer.samplesPerPixel = quality.samples
        renderer.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.status = status } }
        renderer.onRecordingInterrupted = { [weak self] in
            MainActor.assumeIsolated { self?.stopRecording(note: "Recording stopped: the window changed size") }
        }
        renderer.onIterationProposal = { [weak self] limit in MainActor.assumeIsolated { self?.iteration.maxIter = limit } }
        engine.references.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.renderer.invalidate() }
        }
        renderer.onFrame = { [weak self] dt in MainActor.assumeIsolated { self?.tick(dt) } }
        export.announce = { [weak self] message in self?.announce(message, duration: 3) }
        renderer.onProbe = { [weak self] probe in
            MainActor.assumeIsolated {
                guard let self, self.autopilotEngaged else { return }
                self.autopilot.steer(with: probe, formula: self.formula)
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

    /// What the next launch restores: the view, colours, quality and iteration mode.
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
                             palette: color.palette, maxIter: iteration.maxIter)
        let session = Session(place: place, color: color, quality: quality.rawValue, autoIterations: iteration.autoIterations)
        guard let data = try? JSONEncoder().encode(session), data != lastSavedSession else { return }
        lastSavedSession = data
        UserDefaults.standard.set(data, forKey: AppModel.sessionKey)
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              let view = session.place.viewport else { return }
        formula = session.place.formula
        color = session.color
        quality = Quality(rawValue: session.quality) ?? quality
        iteration.autoIterations = session.autoIterations
        if let limit = session.place.maxIter { iteration.maxIter = limit }
        camera.jump(to: view)
        lastSavedSession = data
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.bookmarksKey),
              let saved = try? JSONDecoder().decode([Location].self, from: data) else { return }
        bookmarks = saved
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: AppModel.bookmarksKey) }
    }

    func addBookmark() {
        let view = camera.view
        let place = Location(id: "bm-" + UUID().uuidString, name: "\(formula.displayName) · " + Magnification.text(view.zoomLog10),
                             formula: formula, view: view, palette: color.palette, maxIter: iteration.maxIter)
        bookmarks.insert(place, at: 0)
        saveBookmarks()
        announce("Saved to Your Places")
    }

    func removeBookmark(_ place: Location) {
        bookmarks.removeAll { $0.id == place.id }
        saveBookmarks()
    }

    // MARK: Navigation

    /// Ends the tour, and an autopilot that is flying somewhere, when the user takes over.
    func userInteracted() {
        if autopilotEngaged && camera.isFlying { autopilotEngaged = false }
        if touring { stopTour() }
    }

    func goHome() {
        autopilotEngaged = false
        camera.fly(to: Viewport.home(for: formula), duration: 1.4)
    }

    func fly(to location: Location, quietly: Bool = false) {
        autopilotEngaged = false
        if location.formula != formula {
            formula = location.formula
            camera.jump(to: Viewport.home(for: formula))
        }
        if let palette = location.palette { setPalette(palette) }
        if let limit = location.maxIter { iteration.maxIter = max(iteration.maxIter, limit) }
        guard let view = location.viewport else { return }
        renderer.snapColors = true
        camera.fly(to: view)
        if !quietly { announce("\(location.name) · " + Magnification.text(location.zoom)) }
    }

    /// Zooms about the centre of the view (menu and keyboard).
    func zoomStep(_ log2Factor: Double) {
        let size = renderer.drawableSize
        camera.zoom(log2Factor: log2Factor, at: SIMD2(Double(size.x), Double(size.y)) * 0.5, width: size.x, height: size.y,
                    animated: true)
    }

    func selectFamily(_ family: FractalFamily, power: Int? = nil) {
        var selected = formula
        selected.family = family
        if let power { selected.power = power }
        selected.julia = false
        guard selected != formula else { return }
        formula = selected
        renderer.snapColors = true
        camera.jump(to: Viewport.home(for: selected))
    }

    /// Switches between the parameter plane and the Julia set of the view centre.
    func toggleJulia() {
        let c = camera.view.center
        let toggled = formula.julia ? formula.parameterPlane : formula.juliaSet(re: c.re.doubleValue, im: c.im.doubleValue)
        openJulia(toggled)
        announce(toggled.julia ? "Julia set for c = \(juliaText(toggled))" : "Mandelbrot set")
    }

    /// Opens the Julia set of the parameter at drawable pixel `pixel`.
    func pickJulia(atPixel pixel: SIMD2<Double>) {
        let size = renderer.drawableSize
        let c = camera.view.point(atPixel: pixel, width: size.x, height: size.y, flipY: formula.family.flipY)
        let julia = formula.juliaSet(re: c.re.doubleValue, im: c.im.doubleValue)
        juliaHover = nil
        openJulia(julia)
        announce("Julia set for c = \(juliaText(julia))")
    }

    private func openJulia(_ julia: Formula) {
        formula = julia
        camera.jump(to: Viewport.home(for: julia))
        renderer.snapColors = true
    }

    private func juliaText(_ formula: Formula) -> String {
        String(format: "%.5f %+.5fi", formula.juliaRe, formula.juliaIm)
    }

    /// Records the view once the camera has rested for a moment after moving.
    private func recordHistory() {
        let now = CACurrentMediaTime()
        if camera.isAnimating || touring || autopilotEngaged {
            restSince = now
            return
        }
        guard camera.version != lastRestVersion, now - restSince > 0.8 else { return }
        lastRestVersion = camera.version
        if historyIndex >= 0, historyIndex < history.count,
           let current = history[historyIndex].viewport, abs(current.log2Radius - camera.view.log2Radius) < 0.3,
           camera.view.center.minus(current.center).log2Abs < current.log2Radius - 3 {
            return   // barely moved
        }
        let place = Location(id: "h\(camera.version)", name: "History", formula: formula, view: camera.view,
                             palette: color.palette, maxIter: nil)
        history = Array(history.prefix(historyIndex + 1)) + [place]
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = history.count - 1
    }

    func goBack() { stepHistory(-1) }
    func goForward() { stepHistory(1) }

    private func stepHistory(_ step: Int) {
        let index = historyIndex + step
        guard index >= 0, index < history.count, let view = history[index].viewport else {
            announce(step < 0 ? "Start of history" : "End of history")
            return
        }
        historyIndex = index
        if history[index].formula != formula {
            formula = history[index].formula
            camera.jump(to: Viewport.home(for: formula))
        }
        renderer.snapColors = true
        camera.fly(to: view, duration: min(3, max(0.8, abs(view.log2Radius - camera.view.log2Radius) * 0.06)))
        lastRestVersion = -1
    }

    /// The view as text that `goTo(text:)` accepts.
    var coordinatesText: String {
        let view = camera.view
        let digits = Int(view.zoomLog10) + 10
        return "re: \(view.center.re.string(digits: digits))\nim: \(view.center.im.string(digits: digits))\nzoom: \(view.zoomText)"
    }

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
                let value = parts[1].replacingOccurrences(of: "×", with: "")
                if let e = value.range(of: "e", options: .caseInsensitive), let mantissa = Double(value[..<e.lowerBound]),
                   let exponent = Double(value[e.upperBound...]) {
                    zoom = log10(mantissa) + exponent
                } else if let magnification = Double(value) {
                    zoom = log10(max(magnification, 1e-9))
                }
            default: break
            }
        }
        if re == nil {
            let numbers = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).map(String.init)
            if numbers.count >= 2 { (re, im) = (numbers[0], numbers[1]) }
            if numbers.count >= 3 { zoom = Double(numbers[2]) }
        }
        guard let re, let im else { return false }
        let zoomLog10 = zoom ?? camera.view.zoomLog10
        let place = Location(id: "goto", name: "Coordinates", formula: formula, re: re, im: im, zoom: zoomLog10)
        guard let view = place.viewport else { return false }
        renderer.snapColors = true
        camera.fly(to: view)
        announce("Flying to " + Magnification.text(zoomLog10))
        return true
    }

    // MARK: Minibrots

    /// Locates the lowest-period minibrot in view (quadratic Mandelbrot only) and flies to it.
    func findMinibrot() {
        guard formula.supportsMinibrotSearch else {
            announce("Mini-Mandelbrot search works in the Mandelbrot set")
            return
        }
        guard !searchingMinibrot else { return }
        searchingMinibrot = true
        autopilotEngaged = false
        stopTour()
        announce("Searching for a mini-Mandelbrot…")
        let view = camera.view
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = AppModel.locateMinibrot(in: view)
            await MainActor.run { [weak self] in
                guard let self else { return }
                searchingMinibrot = false
                guard let found else {
                    announce("No mini-Mandelbrot found here — try zooming closer to the edge")
                    return
                }
                renderer.snapColors = true
                camera.fly(to: found.view)
                announceMinibrot(period: found.period, log2Size: found.log2Size)
            }
        }
    }

    /// The minibrot whose nucleus lies in or near `view`, if any: a view framing it, its period and log2 size.
    nonisolated private static func locateMinibrot(in view: Viewport) -> (view: Viewport, period: Int, log2Size: Double)? {
        guard let found = Minibrot.locate(near: view.center, searchLog2Radius: view.log2Radius,
                                          viewLog2Radius: view.log2Radius, maxPeriod: 2_000_000),
              found.cardioid, found.log2Size.isFinite, found.log2Size < view.log2Radius,
              found.nucleus.minus(view.center).log2Abs < view.log2Radius + 2 else { return nil }
        let framing = Viewport(center: found.nucleus, log2Radius: found.log2Size + log2(2.6), rotation: view.rotation)
        return (framing, found.period, found.log2Size)
    }

    func announceMinibrot(period: Int, log2Size: Double) {
        announce("Mini-Mandelbrot of period \(period.formatted()) · "
                 + Magnification.text(Viewport.zoomLog10(log2Radius: log2Size)), duration: 2.5)
    }

    /// Shows the orbit of the point at drawable pixel `pixel` (`scale`: pixels per point).
    func showOrbit(atPixel pixel: SIMD2<Double>, scale: Double) {
        orbitHover = OrbitHover(formula: formula, view: camera.view, cameraVersion: camera.version, pixel: pixel,
                                drawableSize: renderer.drawableSize, scale: scale)
    }

    /// Speeds the autopilot up or down (keys , and .).
    func scaleAutopilotSpeed(_ factor: Double) {
        autopilot.speed = min(8, max(0.25, autopilot.speed * factor))
        announce(String(format: "Autopilot speed %.1f×", autopilot.speed))
    }

    // MARK: Colour and iterations

    /// Switches palettes with a short cross-fade.
    func setPalette(_ index: Int) {
        let count = Palette.all.count
        let palette = ((index % count) + count) % count
        guard palette != color.palette else { return }
        paletteFade = (color.palette, palette, 0)
        color.palette = palette
    }

    func cyclePalette(_ step: Int) {
        setPalette(color.palette + step)
        announce(Palette.all[color.palette].name)
    }

    func toggleLighting() {
        color.lightStrength = color.lightStrength > 0 ? 0 : 0.75
        announce(color.lightStrength > 0 ? "Lighting on" : "Lighting off")
    }

    /// Scales the iteration limit by hand, which turns automatic iterations off.
    func scaleIterations(_ factor: Double) {
        iteration.autoIterations = false
        iteration.maxIter = max(64, min(IterationTuner.highestLimit, Int(Double(iteration.maxIter) * factor)))
        announce("Iterations \(iteration.maxIter.formatted())")
    }

    // MARK: Export, recording and the pasteboard

    func openExport(_ kind: ExportController.Kind) {
        export.kind = kind
        showExport = true
    }

    func toggleRecording() {
        if recordingSince == nil { startRecording() } else { stopRecording() }
    }

    /// Records the canvas as shown (without the interface) to a movie, by default in the video export folder.
    func startRecording(to file: URL? = nil) {
        let url = file ?? export.videoFolder.appendingPathComponent(ExportController.defaultName("Spectrum Recording", "mp4"))
        do {
            renderer.recorder = try LiveRecorder(url: url, drawableSize: renderer.drawableSize)
            recordingSince = Date()
            announce("Recording · ⌘R to stop")
        } catch {
            announce("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Finishes the movie; `then` runs once it is written.
    func stopRecording(note: String? = nil, then: (@MainActor () -> Void)? = nil) {
        guard let recorder = renderer.recorder else {
            then?()
            return
        }
        renderer.recorder = nil
        recordingSince = nil
        recorder.finish { written in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.announce(note ?? (written ? "Saved \(recorder.url.lastPathComponent)" : "Recording failed"), duration: 3)
                    then?()
                }
            }
        }
    }

    /// Puts the view as shown (at the canvas resolution) on the pasteboard.
    func copyImage() {
        guard let image = renderer.captureCanvas() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        announce("Image copied")
    }

    func copyCoordinates() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coordinatesText, forType: .string)
        announce("Coordinates copied")
    }

    /// Shows a short notice at the top of the window.
    func announce(_ message: String, duration: Double = 1.6) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Per frame

    private func tick(_ dt: Double) {
        recordHistory()
        if var fade = paletteFade {
            fade.progress += dt / 0.45
            if fade.progress >= 1 {
                paletteFade = nil
                renderer.paletteBlend = nil
                renderer.recolor()
            } else {
                paletteFade = fade
                let eased = Float(fade.progress * fade.progress * (3 - 2 * fade.progress))
                renderer.paletteBlend = Engine.PaletteBlend(from: fade.from, to: fade.to, mix: eased)
            }
        }
        if cycleColors {
            color.offset = (color.offset + dt * AppModel.colorCycleSpeed).truncatingRemainder(dividingBy: 1)
        }
        if autopilotEngaged && !autopilot.step(dt: dt, flipY: formula.family.flipY) { autopilotEngaged = false }
        if let orbit = orbitHover, orbit.cameraVersion != camera.version { showOrbit(atPixel: orbit.pixel, scale: orbit.scale) }
    }

    private func formulaChanged(from old: Formula) {
        renderer.formula = formula
        // targets (and a minibrot being approached) belong to the old set
        if formula != old { autopilot.reset() }
        if formula.family != old.family || formula.effectivePower != old.effectivePower || formula.julia != old.julia {
            engine.references.reset()
            iteration.maxIter = IterationSettings().maxIter
            iteration.blaLog2Eps = quality.blaLog2Eps
        }
    }
}
