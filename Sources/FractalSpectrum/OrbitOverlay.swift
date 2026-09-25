import SwiftUI
import simd
import FractalKit

/// The orbit of the point under the pointer, in canvas coordinates (points, origin top-left).
struct OrbitHover: Equatable {
    /// Pointer position in drawable pixels, pixels per point, and the camera version the orbit
    /// was computed for.
    var pixel: SIMD2<Double>
    var scale: Double
    var cameraVersion: Int
    var pointer: CGPoint
    var points: [CGPoint]
    var summary: String

    /// Orbit of the sample at drawable pixel `pixel` of `view`; `scale` converts pixels to points.
    init(formula: Formula, view: Viewport, cameraVersion: Int, pixel: SIMD2<Double>, drawable: SIMD2<Int>, scale: Double) {
        self.pixel = pixel
        self.scale = scale
        self.cameraVersion = cameraVersion
        let flipY = formula.family.flipY
        let c = view.point(atPixel: pixel, width: drawable.x, height: drawable.y, flipY: flipY)
        let count = 400
        let zs = formula.orbit(of: c, count: count)
        let limit = Double(max(drawable.x, drawable.y)) * 4
        points = zs.map { z in
            let p = view.pixel(of: PlanePoint(Double(z.x), Double(z.y)), width: drawable.x, height: drawable.y, flipY: flipY)
            return CGPoint(x: min(max(p.x, -limit), limit) / scale, y: min(max(p.y, -limit), limit) / scale)
        }
        pointer = CGPoint(x: pixel.x / scale, y: pixel.y / scale)
        if zs.count < count {
            summary = "Escapes after \(zs.count - 1) iterations"
        } else if let last = zs.last,
                  let period = (1...32).first(where: { simd_distance(last, zs[zs.count - 1 - $0]) < 1e-4 }) {
            summary = period == 1 ? "Settles on a fixed point" : "Settles into a \(period)-cycle"
        } else {
            summary = "Stays bounded"
        }
    }
}

/// Draws the orbit as a fading polyline with dots, plus its summary beside the pointer.
struct OrbitOverlay: View {
    let orbit: OrbitHover

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let pts = orbit.points
                for i in 1..<max(pts.count, 1) {
                    var seg = Path()
                    seg.move(to: pts[i - 1])
                    seg.addLine(to: pts[i])
                    let fade = 0.25 + 0.75 * pow(0.985, Double(i))
                    ctx.stroke(seg, with: .color(.white.opacity(fade)), lineWidth: 1.2)
                }
                for (i, p) in pts.enumerated() {
                    let r = i == 0 ? 4.0 : 2.2
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(i == 0 ? .orange : .white.opacity(0.25 + 0.75 * pow(0.985, Double(i)))))
                }
            }
            Text(orbit.summary)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .panelGlass(in: Capsule())
                .fixedSize()
                .offset(x: orbit.pointer.x + 16, y: orbit.pointer.y + 14)
        }
    }
}
