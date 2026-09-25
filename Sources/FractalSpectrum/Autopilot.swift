import QuartzCore
import FractalKit
import CFractal

/// Endless dive. Follows detailed parts of the boundary (escape times in the upper range, little
/// interior and no noise-like texture around); in the Mandelbrot set it also hops from minibrot to
/// minibrot: one that appears in view is approached until it fills the view, turned upright and shown
/// for a moment.
@MainActor
final class Autopilot {
    /// Zoom speed in doublings per second.
    var speed = 1.0
    /// Called on reaching a minibrot with its period and log2 size.
    var onArrival: ((Int, Double) -> Void)?
    private let camera: Camera
    private let renderer: LiveRenderer
    /// Boundary detail the dive heads for, from the last probe.
    private var target: PlanePoint?
    private var lastProbe = 0.0
    /// The minibrot being approached.
    private var minibrot: FoundMinibrot?
    private var visitedPeriod = 0
    private var dwellUntil = 0.0
    /// After backing out, targets away from the centre are preferred for a while.
    private var exploreUntil = 0.0
    private var backOutUntil = 0.0
    // Motion eases towards what the dive calls for, so new targets, pauses and back-outs never jolt
    // the view: pan and zoom velocity, spin, and the zoom's fixed point (`aim`, kept as an offset
    // from the target's position so that it glides when the target changes).
    private var panVelocity = SIMD2<Double>(0, 0)
    private var zoomVelocity = 0.0
    private var spinVelocity = 0.0
    private var aimOffset = SIMD2<Double>(0, 0)
    private var aimedAt: SIMD2<Double>?
    private var searching = false
    /// Incremented by `reset`, so that searches started before it are ignored.
    private var session = 0

    private struct FoundMinibrot {
        let nucleus: PlanePoint
        let log2Size: Double
        let angle: Double
        let period: Int
        /// Where the view is centred on arrival (the middle of the minibrot's body).
        let frame: PlanePoint
    }

    init(camera: Camera, renderer: LiveRenderer) {
        self.camera = camera
        self.renderer = renderer
    }

    func reset() {
        target = nil
        minibrot = nil
        visitedPeriod = 0
        dwellUntil = 0
        exploreUntil = 0
        backOutUntil = 0
        panVelocity = .zero
        zoomVelocity = 0
        spinVelocity = 0
        aimOffset = .zero
        aimedAt = nil
        searching = false
        session += 1
    }

    // MARK: Motion

    /// Advances the dive by one frame; false once the deepest supported zoom is reached.
    func step(dt: Double, flipY: Bool) -> Bool {
        let size = renderer.drawableSize
        let centre = SIMD2(Double(size.x), Double(size.y)) * 0.5
        let now = CACurrentMediaTime()
        if now - lastProbe > 0.3 {
            lastProbe = now
            renderer.probeRequested = true
        }
        let dwelling = now < dwellUntil
        // Where the dive heads: the target, or the minibrot's body while approaching one.
        var goal = centre
        if !dwelling, let heading = minibrot?.frame ?? target {
            let p = camera.view.pixel(of: heading, width: size.x, height: size.y, flipY: flipY)
            if p.x < 0 || p.y < 0 || p.x > Double(size.x) || p.y > Double(size.y) {
                if minibrot == nil { target = nil } else { minibrot = nil }
            } else {
                goal = p
            }
        }
        // A new goal keeps the aim where it was; the offset then fades, so the aim glides over.
        if let last = aimedAt, simd_distance(last, goal) > 1 { aimOffset += last - goal }
        aimOffset *= exp(-dt / 0.6)
        let aim = goal + aimOffset
        aimedAt = goal

        panVelocity += ((centre - aim) * 0.9 - panVelocity) * ease(dt, over: 0.4)
        camera.pan(pixels: panVelocity * dt, width: size.x, height: size.y)
        let zoomGoal = now < backOutUntil ? -1.4 * speed : speed * (dwelling ? 0.15 : 1)
        zoomVelocity += (zoomGoal - zoomVelocity) * ease(dt, over: 0.5)
        // zooming about the aim holds it still, so the pan alone brings it to the centre
        camera.zoom(log2Factor: -zoomVelocity * dt, at: aim, width: size.x, height: size.y, animated: false)
        let spinGoal = minibrot.map { remainder($0.angle - camera.view.rotation, 2 * .pi) * 0.8 } ?? 0
        spinVelocity += (spinGoal - spinVelocity) * ease(dt, over: 0.5)
        camera.rotate(by: spinVelocity * dt)

        if let minibrot, camera.view.log2Radius <= minibrot.log2Size + log2(1.5) {
            onArrival?(minibrot.period, minibrot.log2Size)
            visitedPeriod = minibrot.period
            self.minibrot = nil
            target = nil
            dwellUntil = now + 2.5
        }
        return camera.view.log2Radius > Camera.log2RadiusRange.lowerBound + 0.01
    }

    /// Hands the dive's momentum to the camera's own easing, so that stopping slows down smoothly:
    /// each eased remainder starts out at the dive's current velocity.
    func coast() {
        let size = renderer.drawableSize
        let aim = aimedAt.map { $0 + aimOffset } ?? SIMD2(Double(size.x), Double(size.y)) * 0.5
        camera.fling(velocity: panVelocity)
        camera.zoom(log2Factor: -zoomVelocity / Camera.zoomEasing, at: aim, width: size.x, height: size.y, animated: true)
        camera.rotate(by: spinVelocity / Camera.rotationEasing, animated: true)
    }

    /// Share of the way an eased quantity covers in `dt` when it settles over about `seconds`.
    private func ease(_ dt: Double, over seconds: Double) -> Double { 1 - exp(-dt / seconds) }

    // MARK: Steering

    /// Picks the next target from a probe of the preview's escape iterations.
    func steer(with probe: LiveRenderer.Probe, formula: Formula) {
        guard minibrot == nil else { return }
        let grid = ProbeGrid(probe)
        let flipY = formula.family.flipY
        let escaped = grid.iterations.filter { $0 != FS_INTERIOR }
        let noise = grid.noise()
        let noisyCells = noise.filter { $0 > 0 }.count
        let now = CACurrentMediaTime()
        // A minibrot just shown fills much of the view; give the dive time to leave it.
        if now > dwellUntil + 3, escaped.count < grid.count / 20 || Double(grid.count - escaped.count) > Double(grid.count) * 0.6
            || Double(noisyCells) > Double(escaped.count) * 0.45 {
            // mostly interior, noise or nothing to follow: back out and look elsewhere
            target = nil
            exploreUntil = now + 3
            backOutUntil = now + 0.9
            return
        }
        if formula.family == .mandelbrot, formula.effectivePower == 2, !formula.julia, !searching, now > dwellUntil {
            searchMinibrot(in: grid, flipY: flipY)
        }
        guard escaped.count > 20 else { return }
        let sorted = escaped.sorted()
        let low = Double(sorted[sorted.count * 60 / 100]), high = Double(sorted[sorted.count * 97 / 100])
        guard high > low else { return }
        // Scores cells with escape times in the upper range by their surroundings: much interior
        // or noise means a dark or noisy view ahead. Away from the centre is preferred only while exploring.
        let r = max(2, min(grid.width, grid.height) / 16)
        let cx = Double(grid.width) / 2, cy = Double(grid.height) / 2, diagonal = hypot(cx, cy)
        let centreWeight = now < exploreUntil ? 0.6 : -0.9
        var candidates: [(score: Double, x: Int, y: Int)] = []
        for y in r..<(grid.height - r) {
            for x in r..<(grid.width - r) {
                let n = grid[x, y]
                guard n != FS_INTERIOR, Double(n) >= low, Double(n) <= high else { continue }
                var interior = 0, noiseSum: Float = 0, cells = 0, clear = true
                for dy in -r...r {
                    for dx in -r...r {
                        let i = (y + dy) * grid.width + x + dx
                        cells += 1
                        noiseSum += noise[i]
                        if grid.iterations[i] == FS_INTERIOR {
                            interior += 1
                            if abs(dx) <= 1 && abs(dy) <= 1 { clear = false }
                        }
                    }
                }
                guard clear else { continue }
                let score = (Double(n) - low) / (high - low) + centreWeight * hypot(Double(x) - cx, Double(y) - cy) / diagonal
                    - 1.5 * Double(interior) / Double(cells) - 2 * max(0, Double(noiseSum) / Double(cells) - 0.25)
                candidates.append((score, x, y))
            }
        }
        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return }
        // Keep the target while it is nearly as good as the best: switching goals is what makes a
        // dive wander. Otherwise a random pick among the best few varies the path.
        if let target {
            let cell = grid.cell(of: target, flipY: flipY)
            if let current = candidates.first(where: { abs($0.x - cell.x) <= 1 && abs($0.y - cell.y) <= 1 }),
               current.score > best.score - 0.3 { return }
        }
        guard let pick = ranked.prefix(4).randomElement() else { return }
        target = grid.point(x: Double(pick.x), y: Double(pick.y), flipY: flipY)
    }

    /// Looks for a minibrot among the interior blobs of the grid (off the main thread): the nucleus of a
    /// blob's component, kept if it is a cardioid well smaller than the view.
    private func searchMinibrot(in grid: ProbeGrid, flipY: Bool) {
        let starts = grid.interiorBlobs().filter { $0.size < grid.count / 8 }.sorted { $0.size > $1.size }.prefix(4)
            .map { grid.point(x: $0.x, y: $0.y, flipY: flipY) }
        guard !starts.isEmpty else { return }
        searching = true
        let session = self.session, visited = visitedPeriod, view = grid.probe.view
        Task.detached(priority: .utility) { [weak self] in
            let found = Autopilot.findMinibrot(near: starts, view: view, excluding: visited)
            await MainActor.run { [weak self] in
                guard let self, session == self.session else { return }
                searching = false
                // The dive went on meanwhile: the minibrot must still be ahead and in view.
                let v = camera.view
                // Resolving a minibrot's surroundings takes some hundred times its period in iterations.
                guard let found, minibrot == nil, found.log2Size < v.log2Radius - 1,
                      found.nucleus.minus(v.center).log2Abs < v.log2Radius,
                      found.period * 200 <= renderer.affordableIterations else { return }
                minibrot = found
            }
        }
    }

    nonisolated private static func findMinibrot(near starts: [PlanePoint], view: Viewport,
                                                 excluding visited: Int) -> FoundMinibrot? {
        let precision = max(view.center.precision, Int(-view.log2Radius) * 2 + 128)
        for start in starts {
            let period = Minibrot.period(center: start, log2Radius: view.log2Radius - 8, maxPeriod: 1_000_000)
            guard period > 0, period != visited,
                  let nucleus = Minibrot.nucleus(near: start, period: period, precision: precision) else { continue }
            let (log2Size, angle, cardioid) = Minibrot.size(nucleus: nucleus, period: period)
            guard cardioid, log2Size.isFinite, log2Size < view.log2Radius - 3,
                  nucleus.minus(view.center).log2Abs < view.log2Radius else { continue }
            // body centre: nucleus + scale * (-0.6), scale = 2^log2Size e^(i angle)
            let offset = ComplexExp(re: FloatExp.fromLog2(log2Size) * (-0.6 * cos(angle)),
                                    im: FloatExp.fromLog2(log2Size) * (-0.6 * sin(angle)))
            return FoundMinibrot(nucleus: nucleus, log2Size: log2Size, angle: angle, period: period,
                            frame: nucleus.offset(by: offset, precision: precision))
        }
        return nil
    }
}

/// A probe's escape iterations sampled on a grid of about 64 cells along the shorter side.
private struct ProbeGrid {
    let probe: LiveRenderer.Probe
    let width: Int
    let height: Int
    /// Probe samples per cell side.
    let cell: Int
    let iterations: [UInt32]

    init(_ probe: LiveRenderer.Probe) {
        let cell = max(1, min(probe.width, probe.height) / 64)
        let width = (probe.width + cell - 1) / cell, height = (probe.height + cell - 1) / cell
        self.probe = probe
        self.cell = cell
        self.width = width
        self.height = height
        iterations = (0..<height).flatMap { y in
            (0..<width).map { x in probe.iterations[min(y * cell, probe.height - 1) * probe.width + min(x * cell, probe.width - 1)] }
        }
    }

    var count: Int { width * height }
    subscript(x: Int, y: Int) -> UInt32 { iterations[y * width + x] }

    /// 1 for cells whose escape time differs a lot from the next cell's to the right or below:
    /// noise-like texture of chaotic escape times, such as the Burning Ship's flames.
    func noise() -> [Float] {
        var noise = [Float](repeating: 0, count: count)
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let a = self[x, y], b = self[x + 1, y], c = self[x, y + 1]
                guard a != FS_INTERIOR, b != FS_INTERIOR, c != FS_INTERIOR else { continue }
                func differs(_ other: UInt32) -> Bool { abs(log(Double(max(a, 1)) / Double(max(other, 1)))) > 0.5 }
                if differs(b) || differs(c) { noise[y * width + x] = 1 }
            }
        }
        return noise
    }

    /// Connected regions of interior cells: centroid (in cells) and size.
    func interiorBlobs() -> [(x: Double, y: Double, size: Int)] {
        var labelled = [Bool](repeating: false, count: count)
        var blobs: [(x: Double, y: Double, size: Int)] = []
        for i in 0..<count where iterations[i] == FS_INTERIOR && !labelled[i] {
            var stack = [i], sumX = 0.0, sumY = 0.0, size = 0
            labelled[i] = true
            while let j = stack.popLast() {
                let x = j % width, y = j / width
                sumX += Double(x)
                sumY += Double(y)
                size += 1
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height && self[nx, ny] == FS_INTERIOR && !labelled[ny * width + nx] {
                    labelled[ny * width + nx] = true
                    stack.append(ny * width + nx)
                }
            }
            blobs.append((sumX / Double(size), sumY / Double(size), size))
        }
        return blobs
    }

    /// Plane point of cell coordinates.
    func point(x: Double, y: Double, flipY: Bool) -> PlanePoint {
        let pixel = SIMD2(x * Double(cell) + 0.5, y * Double(cell) + 0.5) * Double(probe.drawable.x) / Double(probe.width)
        return probe.view.point(atPixel: pixel, width: probe.drawable.x, height: probe.drawable.y, flipY: flipY)
    }

    /// Cell of a plane point.
    func cell(of point: PlanePoint, flipY: Bool) -> (x: Int, y: Int) {
        let pixel = probe.view.pixel(of: point, width: probe.drawable.x, height: probe.drawable.y, flipY: flipY)
        return (Int(pixel.x * Double(probe.width) / Double(probe.drawable.x)) / cell,
                Int(pixel.y * Double(probe.width) / Double(probe.drawable.x)) / cell)
    }
}
