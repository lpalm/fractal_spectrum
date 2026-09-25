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
    private var minibrot: Found?
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

    private struct Found {
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

    /// Advances the dive by one frame; false once the deepest supported zoom is reached.
    func step(dt: Double, flipY: Bool) -> Bool {
        let s = renderer.drawableSizeForPicking
        let centre = SIMD2(Double(s.x), Double(s.y)) * 0.5
        let now = CACurrentMediaTime()
        if now - lastProbe > 0.3 {
            lastProbe = now
            renderer.probeRequested = true
        }
        let dwelling = now < dwellUntil
        // Where the dive heads: the target, or the minibrot's body while approaching one.
        var goal = centre
        if !dwelling, let t = minibrot?.frame ?? target {
            let p = camera.view.pixel(of: t, width: s.x, height: s.y, flipY: flipY)
            if p.x < 0 || p.y < 0 || p.x > Double(s.x) || p.y > Double(s.y) {
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
        camera.pan(pixels: panVelocity * dt, width: s.x, height: s.y)
        let zoomGoal = now < backOutUntil ? -1.4 * speed : speed * (dwelling ? 0.15 : 1)
        zoomVelocity += (zoomGoal - zoomVelocity) * ease(dt, over: 0.5)
        // zooming about the aim holds it still, so the pan alone brings it to the centre
        camera.zoom(log2Factor: -zoomVelocity * dt, at: aim, width: s.x, height: s.y, animated: false)
        let spinGoal = minibrot.map { remainder($0.angle - camera.view.rotation, 2 * .pi) * 0.8 } ?? 0
        spinVelocity += (spinGoal - spinVelocity) * ease(dt, over: 0.5)
        camera.rotate(by: spinVelocity * dt)

        if let m = minibrot, camera.view.log2Radius <= m.log2Size + log2(1.5) {
            onArrival?(m.period, m.log2Size)
            visitedPeriod = m.period
            minibrot = nil
            target = nil
            dwellUntil = now + 2.5
        }
        return camera.view.log2Radius > Camera.log2RadiusRange.lowerBound + 0.01
    }

    /// Hands the dive's momentum to the camera's own easing, so that stopping slows down smoothly:
    /// each eased remainder starts out at the dive's current velocity.
    func coast() {
        let s = renderer.drawableSizeForPicking
        let aim = aimedAt.map { $0 + aimOffset } ?? SIMD2(Double(s.x), Double(s.y)) * 0.5
        camera.fling(velocity: panVelocity)
        camera.zoom(log2Factor: -zoomVelocity / Camera.zoomEasing, at: aim, width: s.x, height: s.y, animated: true)
        camera.rotate(by: spinVelocity / Camera.rotationEasing, animated: true)
    }

    /// Share of the way an eased quantity covers in `dt` when it settles over about `seconds`.
    private func ease(_ dt: Double, over seconds: Double) -> Double { 1 - exp(-dt / seconds) }

    /// Picks the next target from a probe of the preview's escape iterations.
    func steer(with probe: LiveRenderer.Probe, formula: Formula) {
        guard minibrot == nil else { return }
        let w = probe.width, h = probe.height
        let step = max(1, min(w, h) / 64)
        let gw = (w + step - 1) / step, gh = (h + step - 1) / step
        var grid = [UInt32](repeating: 0, count: gw * gh)
        var escaped: [UInt32] = []
        for gy in 0..<gh {
            for gx in 0..<gw {
                let n = probe.iterations[min(gy * step, h - 1) * w + min(gx * step, w - 1)]
                grid[gy * gw + gx] = n
                if n != FS_INTERIOR { escaped.append(n) }
            }
        }
        // Noise-like texture (chaotic escape times, e.g. the Burning Ship's flames): neighbouring
        // cells whose escape times differ a lot.
        var jump = [Float](repeating: 0, count: gw * gh)
        var jumps = 0
        for gy in 0..<(gh - 1) {
            for gx in 0..<(gw - 1) {
                let a = grid[gy * gw + gx], b = grid[gy * gw + gx + 1], c = grid[(gy + 1) * gw + gx]
                guard a != FS_INTERIOR, b != FS_INTERIOR, c != FS_INTERIOR else { continue }
                if abs(log(Double(max(a, 1)) / Double(max(b, 1)))) > 0.5 || abs(log(Double(max(a, 1)) / Double(max(c, 1)))) > 0.5 {
                    jump[gy * gw + gx] = 1
                    jumps += 1
                }
            }
        }
        let now = CACurrentMediaTime()
        // A minibrot just shown fills much of the view; give the dive time to leave it.
        if now > dwellUntil + 3, escaped.count < gw * gh / 20 || Double(gw * gh - escaped.count) > Double(gw * gh) * 0.6
            || Double(jumps) > Double(escaped.count) * 0.45 {
            // mostly interior, noise or nothing to follow: back out and look elsewhere
            target = nil
            exploreUntil = now + 3
            backOutUntil = now + 0.9
            return
        }
        if formula.family == .mandelbrot, formula.effectivePower == 2, !formula.julia, !searching, now > dwellUntil {
            searchMinibrot(in: grid, gw: gw, gh: gh, cell: step, probe: probe, flipY: formula.family.flipY)
        }
        guard escaped.count > 20 else { return }
        escaped.sort()
        let lo = Double(escaped[escaped.count * 60 / 100]), hi = Double(escaped[escaped.count * 97 / 100])
        guard hi > lo else { return }
        // Around each candidate: the share of interior and of noise (much of either means a dark or
        // noisy view ahead).
        let r = max(2, min(gw, gh) / 16)
        var candidates: [(score: Double, x: Int, y: Int)] = []
        let cx = Double(gw) / 2, cy = Double(gh) / 2, diag = hypot(cx, cy)
        let centre = now < exploreUntil ? 0.6 : -0.9
        for gy in r..<(gh - r) {
            for gx in r..<(gw - r) {
                let v = grid[gy * gw + gx]
                guard v != FS_INTERIOR, Double(v) >= lo, Double(v) <= hi else { continue }
                var inside = 0, noise: Float = 0, cells = 0, clear = true
                for dy in -r...r {
                    for dx in -r...r {
                        let i = (gy + dy) * gw + gx + dx
                        cells += 1
                        noise += jump[i]
                        if grid[i] == FS_INTERIOR {
                            inside += 1
                            if abs(dx) <= 1 && abs(dy) <= 1 { clear = false }
                        }
                    }
                }
                guard clear else { continue }
                let score = (Double(v) - lo) / (hi - lo) + centre * hypot(Double(gx) - cx, Double(gy) - cy) / diag
                    - 1.5 * Double(inside) / Double(cells) - 2 * max(0, Double(noise) / Double(cells) - 0.25)
                candidates.append((score, gx, gy))
            }
        }
        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return }
        // Keep the target while it is nearly as good as the best: switching goals is what makes a
        // dive wander. Otherwise a random pick among the best few varies the path.
        if let t = target {
            let px = probe.view.pixel(of: t, width: probe.drawable.x, height: probe.drawable.y, flipY: formula.family.flipY)
            let gx = Int(px.x * Double(probe.width) / Double(probe.drawable.x)) / step
            let gy = Int(px.y * Double(probe.width) / Double(probe.drawable.x)) / step
            if let current = candidates.first(where: { abs($0.x - gx) <= 1 && abs($0.y - gy) <= 1 }),
               current.score > best.score - 0.3 { return }
        }
        guard let b = ranked.prefix(4).randomElement() else { return }
        target = point(gridX: Double(b.x), gridY: Double(b.y), cell: step, probe: probe, flipY: formula.family.flipY)
    }

    private func point(gridX: Double, gridY: Double, cell: Int, probe: LiveRenderer.Probe, flipY: Bool) -> PlanePoint {
        let px = SIMD2(gridX * Double(cell) + 0.5, gridY * Double(cell) + 0.5) * Double(probe.drawable.x) / Double(probe.width)
        return probe.view.point(atPixel: px, width: probe.drawable.x, height: probe.drawable.y, flipY: flipY)
    }

    /// Looks for a minibrot among the interior blobs of the grid (off the main thread): the nucleus of a
    /// blob's component, kept if it is a cardioid well smaller than the view.
    private func searchMinibrot(in grid: [UInt32], gw: Int, gh: Int, cell: Int, probe: LiveRenderer.Probe, flipY: Bool) {
        var label = [Bool](repeating: false, count: gw * gh)
        var blobs: [(x: Double, y: Double, size: Int)] = []
        for i in 0..<(gw * gh) where grid[i] == FS_INTERIOR && !label[i] {
            var stack = [i], sx = 0.0, sy = 0.0, n = 0
            label[i] = true
            while let j = stack.popLast() {
                sx += Double(j % gw)
                sy += Double(j / gw)
                n += 1
                let x = j % gw, y = j / gw
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < gw && ny < gh && grid[ny * gw + nx] == FS_INTERIOR && !label[ny * gw + nx] {
                    label[ny * gw + nx] = true
                    stack.append(ny * gw + nx)
                }
            }
            blobs.append((sx / Double(n), sy / Double(n), n))
        }
        let starts = blobs.filter { $0.size < gw * gh / 8 }.sorted { $0.size > $1.size }.prefix(4)
            .map { point(gridX: $0.x, gridY: $0.y, cell: cell, probe: probe, flipY: flipY) }
        guard !starts.isEmpty else { return }
        searching = true
        let session = self.session, visited = visitedPeriod, view = probe.view
        Task.detached(priority: .utility) { [weak self] in
            let found = Autopilot.nucleus(near: starts, view: view, excluding: visited)
            await MainActor.run { [weak self] in
                guard let self, session == self.session else { return }
                self.searching = false
                // The dive went on meanwhile: the minibrot must still be ahead and in view.
                let v = self.camera.view
                // Resolving a minibrot's surroundings takes some hundred times its period in iterations.
                guard let f = found, self.minibrot == nil, f.log2Size < v.log2Radius - 1,
                      f.nucleus.minus(v.center).log2Abs < v.log2Radius,
                      f.period * 200 <= self.renderer.affordableIterations else { return }
                self.minibrot = f
            }
        }
    }

    nonisolated private static func nucleus(near starts: [PlanePoint], view: Viewport, excluding visited: Int) -> Found? {
        let precision = max(view.center.precision, Int(-view.log2Radius) * 2 + 128)
        for c in starts {
            let p = Minibrot.period(center: c, log2Radius: view.log2Radius - 8, maxPeriod: 1_000_000)
            guard p > 0, p != visited, let n = Minibrot.nucleus(near: c, period: p, precision: precision) else { continue }
            let (ls, angle, cardioid) = Minibrot.size(nucleus: n, period: p)
            guard cardioid, ls.isFinite, ls < view.log2Radius - 3, n.minus(view.center).log2Abs < view.log2Radius else { continue }
            // body centre: nucleus + scale * (-0.6), scale = 2^ls e^(i angle)
            let off = ComplexExp(re: FloatExp.fromLog2(ls) * (-0.6 * cos(angle)), im: FloatExp.fromLog2(ls) * (-0.6 * sin(angle)))
            return Found(nucleus: n, log2Size: ls, angle: angle, period: p, frame: n.offset(by: off, precision: precision))
        }
        return nil
    }
}
