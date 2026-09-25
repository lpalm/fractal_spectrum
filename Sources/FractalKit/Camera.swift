import Foundation
import simd

extension Viewport {
    /// log2 of the plane distance between adjacent pixels of a width x height image.
    public func log2Step(width: Int, height: Int) -> Double {
        log2Radius + 1 - log2(Double(max(1, min(width, height))))
    }

    /// Plane directions of +1 pixel in x and y (screen y points down), in units of the pixel step.
    public func basis(flipY: Bool) -> (x: SIMD2<Double>, y: SIMD2<Double>) {
        let c = cos(rotation), s = sin(rotation), fy = flipY ? -1.0 : 1.0
        return (SIMD2(c, s), SIMD2(s * fy, -c * fy))
    }

    /// Plane offset of a pixel displacement.
    public func planeDelta(pixels q: SIMD2<Double>, width: Int, height: Int, flipY: Bool) -> ComplexExp {
        let step = FloatExp.fromLog2(log2Step(width: width, height: height))
        let b = basis(flipY: flipY)
        let d = q.x * b.x + q.y * b.y
        return ComplexExp(re: step * d.x, im: step * d.y)
    }

    /// Plane point at continuous pixel coordinates (origin top-left, y down).
    public func point(atPixel p: SIMD2<Double>, width: Int, height: Int, flipY: Bool) -> PlanePoint {
        let q = p - SIMD2(Double(width), Double(height)) * 0.5
        return center.offset(by: planeDelta(pixels: q, width: width, height: height, flipY: flipY),
                             precision: center.precision)
    }

    /// Pixel coordinates (origin top-left) of a plane point; far-away points saturate.
    public func pixel(of p: PlanePoint, width: Int, height: Int, flipY: Bool) -> SIMD2<Double> {
        let d = p.minus(center)
        let l2 = log2Step(width: width, height: height)
        let x = scalbn(d.re.m, d.re.e - Int(floor(l2))) / exp2(l2 - floor(l2))
        let y = scalbn(d.im.m, d.im.e - Int(floor(l2))) / exp2(l2 - floor(l2))
        let b = basis(flipY: flipY)
        // invert [b.x b.y] (orthonormal up to a reflection)
        let det = b.x.x * b.y.y - b.y.x * b.x.y
        let qx = (b.y.y * x - b.y.x * y) / det
        let qy = (-b.x.y * x + b.x.x * y) / det
        func clampHuge(_ v: Double) -> Double { v.isFinite ? max(-1e9, min(1e9, v)) : 1e9 }
        return SIMD2(clampHuge(qx), clampHuge(qy)) + SIMD2(Double(width), Double(height)) * 0.5
    }

    /// Maps centred pixels of `self` to centred pixels of an image rendered for `source`.
    public func reprojection(from source: Viewport, width: Int, height: Int, flipY: Bool) -> Engine.Reprojection {
        let ls = source.log2Step(width: width, height: height)
        let lc = log2Step(width: width, height: height)
        let bs = source.basis(flipY: flipY), bc = basis(flipY: flipY)
        // M = [bx by] * step; A = Ms^-1 Mc
        let det = bs.x.x * bs.y.y - bs.y.x * bs.x.y
        let inv = (SIMD2(bs.y.y / det, -bs.y.x / det), SIMD2(-bs.x.y / det, bs.x.x / det))   // rows
        let k = exp2(lc - ls)
        let m00 = inv.0.x * bc.x.x + inv.0.y * bc.x.y, m01 = inv.0.x * bc.y.x + inv.0.y * bc.y.y
        let m10 = inv.1.x * bc.x.x + inv.1.y * bc.x.y, m11 = inv.1.x * bc.y.x + inv.1.y * bc.y.y
        let d = center.minus(source.center)
        let fl = floor(ls)
        func toSourcePixels(_ v: FloatExp) -> Double {
            let r = scalbn(v.m, v.e - Int(fl)) / exp2(ls - fl)
            return r.isFinite ? max(-1e7, min(1e7, r)) : 1e7
        }
        let dx = toSourcePixels(d.re), dy = toSourcePixels(d.im)
        let bx = inv.0.x * dx + inv.0.y * dy, by = inv.1.x * dx + inv.1.y * dy
        let same = abs(k - 1) < 1e-9 && abs(bx) < 1e-6 && abs(by) < 1e-6 && abs(rotation - source.rotation) < 1e-9
        return Engine.Reprojection(A: SIMD4(Float(m00 * k), Float(m01 * k), Float(m10 * k), Float(m11 * k)),
                                   b: SIMD2(Float(bx), Float(by)), identity: same)
    }

    /// Same view with enough precision for its zoom level.
    public func normalizedPrecision() -> Viewport {
        var v = self
        let need = max(64, Int(-log2Radius) + 96)
        if v.center.precision < need || v.center.precision > need + 256 { v.center = v.center.withPrecision(need) }
        return v
    }
}

/// Smooth zoom-and-pan path between two views (van Wijk & Nuij), evaluated in log space so that
/// flights between views many orders of magnitude apart stay exact.
public struct Flight: @unchecked Sendable {
    public let start: Viewport
    public let end: Viewport
    public let duration: Double
    private let d: ComplexExp
    private let rho = 1.42
    private let lnL: Double      // ln |end - start|
    private let lw0: Double, lw1: Double
    private let r0: Double, r1: Double
    public let pathLength: Double
    private let pureZoom: Bool

    public init(from a: Viewport, to b: Viewport, duration: Double? = nil) {
        start = a
        end = b
        d = b.center.minus(a.center)
        let ln2 = log(2.0)
        let lu = d.log2Abs * ln2
        let la = a.log2Radius * ln2, lb = b.log2Radius * ln2
        pureZoom = !lu.isFinite || lu < min(la, lb) - 8
        lnL = lu.isFinite ? lu : 0
        lw0 = la - lnL
        lw1 = lb - lnL
        let rho2 = rho * rho, rho4 = rho2 * rho2
        if pureZoom {
            r0 = 0
            r1 = 0
            pathLength = abs(lb - la) / rho
        } else {
            // b_i = (w1^2 - w0^2 +- rho^4) / (2 rho^2 w_i), with w in units of |d|
            func asinhOf(_ num: Double, lnDen: Double) -> Double {
                let lnb = log(abs(num)) - lnDen
                if lnb > 30 { return (num < 0 ? -1 : 1) * (lnb + log(2.0)) }
                return asinh(num * exp(-lnDen))
            }
            let e0 = lw0 < 300 ? exp(2 * lw0) : .infinity, e1 = lw1 < 300 ? exp(2 * lw1) : .infinity
            let n0 = e1 - e0 + rho4, n1 = e1 - e0 - rho4
            r0 = -asinhOf(n0, lnDen: log(2 * rho2) + lw0)
            r1 = -asinhOf(n1, lnDen: log(2 * rho2) + lw1)
            pathLength = (r1 - r0) / rho
        }
        self.duration = duration ?? min(14, max(1.2, 0.55 * pathLength))
    }

    private static func lncosh(_ x: Double) -> Double { abs(x) + log1p(exp(-2 * abs(x))) - log(2.0) }
    private static func lnsinh(_ x: Double) -> Double {
        if x < 1e-4 { return log(max(x, 1e-300)) }
        return x + log1p(-exp(-2 * x)) - log(2.0)
    }

    /// View at normalised time t in [0, 1] (eased).
    public func view(at t: Double) -> Viewport {
        let tt = min(max(t, 0), 1)
        let e = tt * tt * tt * (tt * (tt * 6 - 15) + 10)
        let s = e * pathLength
        var v = end
        v.rotation = start.rotation + (end.rotation - start.rotation) * e
        let ln2 = log(2.0)
        if pureZoom {
            v.log2Radius = start.log2Radius + (end.log2Radius - start.log2Radius) * e
            let prec = max(start.center.precision, end.center.precision)
            v.center = start.center.lerp(to: end.center, e, precision: prec)
            return v
        }
        let lnw = lw0 + Flight.lncosh(r0) - Flight.lncosh(rho * s + r0)
        v.log2Radius = (lnw + lnL) / ln2
        let prec = max(start.center.precision, end.center.precision)
        let lnu = lw0 + Flight.lnsinh(rho * s) - Flight.lncosh(rho * s + r0) - 2 * log(rho)
        let u = s <= 0 ? 0 : exp(lnu)
        if u < 0.5 {
            v.center = start.center.offset(by: d * u, precision: prec)
        } else {
            let rest = pathLength - s
            let ln1u = lw1 + Flight.lnsinh(rho * rest) - Flight.lncosh(rho * rest - r1) - 2 * log(rho)
            let w = rest <= 0 ? 0 : exp(ln1u)
            v.center = end.center.offset(by: d * (-w), precision: prec)
        }
        return v
    }
}

/// Destination of the current camera motion.
public struct Focus: @unchecked Sendable {
    public var point: PlanePoint
    public var log2Radius: Double
}

/// Interactive camera: animated zoom around an anchor, drag panning with inertia, rotation and flights.
public final class Camera: @unchecked Sendable {
    public private(set) var view: Viewport { didSet { version &+= 1 } }
    /// Incremented on every change of `view`.
    public private(set) var version = 0
    public var flipY = false
    private var zoomRemaining = 0.0
    private var anchorPixel: SIMD2<Double>?
    private var velocity = SIMD2<Double>(0, 0)
    private var rotationRemaining = 0.0
    private var flight: Flight?
    private var flightTime = 0.0
    public var minLog2Radius = -60_000.0
    public var maxLog2Radius = 3.0

    public init(view: Viewport) {
        self.view = view.normalizedPrecision()
    }

    public var isFlying: Bool { flight != nil }
    public var flightTarget: Viewport? { flight?.end }
    /// How far the current flight has come, from 0 to 1; nil when not flying.
    public var flightProgress: Double? { flight.map { min(flightTime / $0.duration, 1) } }
    public var isAnimating: Bool {
        flight != nil || abs(zoomRemaining) > 1e-4 || simd_length(velocity) > 2 || abs(rotationRemaining) > 1e-4
    }

    /// Where the camera is heading and how deep: a good place (and precision) for a new reference orbit.
    public func focus(width: Int, height: Int) -> Focus? {
        if let f = flight { return Focus(point: f.end.center, log2Radius: f.end.log2Radius) }
        // Zooming in keeps the anchor at a fixed screen offset, so a reference there stays in view.
        if let a = anchorPixel, zoomRemaining < -0.05 {
            return Focus(point: view.point(atPixel: a, width: width, height: height, flipY: flipY),
                         log2Radius: view.log2Radius + zoomRemaining)
        }
        return nil
    }

    public func jump(to v: Viewport) {
        flight = nil
        zoomRemaining = 0
        velocity = .zero
        rotationRemaining = 0
        view = v.normalizedPrecision()
    }

    public func fly(to v: Viewport, duration: Double? = nil) {
        velocity = .zero
        zoomRemaining = 0
        rotationRemaining = 0
        flight = Flight(from: view, to: v.normalizedPrecision(), duration: duration)
        flightTime = 0
    }

    public func cancelFlight() { flight = nil }

    /// Zooms by 2^log2Factor (negative = in) keeping the plane point under `pixel` fixed.
    public func zoom(log2Factor: Double, at pixel: SIMD2<Double>, width: Int, height: Int, animated: Bool) {
        flight = nil
        if animated {
            zoomRemaining += log2Factor
            anchorPixel = pixel
        } else {
            applyZoom(log2Factor, at: pixel, width: width, height: height)
        }
    }

    private func applyZoom(_ delta: Double, at pixel: SIMD2<Double>, width: Int, height: Int) {
        let lo = minLog2Radius, hi = maxLog2Radius
        let target = min(max(view.log2Radius + delta, lo), hi)
        let actual = target - view.log2Radius
        if actual == 0 { return }
        let q = pixel - SIMD2(Double(width), Double(height)) * 0.5
        // keep the anchor fixed: centre moves along (centre - anchor) by (2^delta - 1)
        let off = view.planeDelta(pixels: q, width: width, height: height, flipY: flipY)
        let k = 1 - exp2(actual)
        view.log2Radius = target
        view.center = view.center.offset(by: off * k, precision: view.center.precision)
        view = view.normalizedPrecision()
    }

    /// Moves the content by a pixel displacement (content follows the cursor).
    public func pan(pixels d: SIMD2<Double>, width: Int, height: Int) {
        flight = nil
        let off = view.planeDelta(pixels: -d, width: width, height: height, flipY: flipY)
        view.center = view.center.offset(by: off, precision: view.center.precision)
    }

    public func fling(velocity v: SIMD2<Double>) { velocity = v }
    public func stopMotion() {
        velocity = .zero
        zoomRemaining = 0
        rotationRemaining = 0
    }

    public func rotate(by radians: Double, animated: Bool = false) {
        flight = nil
        if animated { rotationRemaining += radians } else { view.rotation += radians }
    }

    /// Advances animations; returns true when the view changed.
    public func update(dt: Double, width: Int, height: Int) -> Bool {
        var changed = false
        if let f = flight {
            flightTime += dt
            let t = flightTime / f.duration
            view = f.view(at: t).normalizedPrecision()
            if t >= 1 {
                view = f.end
                flight = nil
            }
            return true
        }
        if abs(zoomRemaining) > 1e-4 {
            let step = zoomRemaining * (1 - exp(-dt * 14))
            zoomRemaining -= step
            if abs(zoomRemaining) <= 1e-4 {
                applyZoom(step + zoomRemaining, at: anchorPixel ?? SIMD2(Double(width), Double(height)) * 0.5,
                          width: width, height: height)
                zoomRemaining = 0
            } else {
                applyZoom(step, at: anchorPixel ?? SIMD2(Double(width), Double(height)) * 0.5, width: width, height: height)
            }
            changed = true
        }
        if simd_length(velocity) > 2 {
            pan(pixels: velocity * dt, width: width, height: height)
            velocity *= exp(-dt * 4.5)
            changed = true
        } else {
            velocity = .zero
        }
        if abs(rotationRemaining) > 1e-4 {
            let step = rotationRemaining * (1 - exp(-dt * 12))
            rotationRemaining -= step
            view.rotation += step
            changed = true
        }
        return changed
    }
}
