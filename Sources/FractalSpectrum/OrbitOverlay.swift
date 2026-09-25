import SwiftUI
import simd
import FractalKit

/// The orbit of the point under the pointer, in canvas coordinates (points, origin top-left).
struct OrbitHover: Equatable {
    /// Where the orbit was computed: the pointer in drawable pixels, pixels per point, and the camera
    /// version (the orbit follows the camera).
    var pixel: SIMD2<Double>
    var scale: Double
    var cameraVersion: Int
    /// The pointer and the orbit's points, in canvas points.
    var pointer: CGPoint
    var points: [CGPoint]
    /// How the orbit ends: it escapes, settles into a cycle or stays bounded.
    var summary: String

    /// Orbit of the sample at drawable pixel `pixel` of `view`; `scale` converts pixels to points.
    init(formula: Formula, view: Viewport, cameraVersion: Int, pixel: SIMD2<Double>, drawable: SIMD2<Int>, scale: Double) {
        self.pixel = pixel
        self.scale = scale
        self.cameraVersion = cameraVersion
        let flipY = formula.family.flipY
        let c = view.point(atPixel: pixel, width: drawable.x, height: drawable.y, flipY: flipY)
        let length = 400
        let orbit = formula.orbit(of: c, count: length)
        // far-away points are drawn at the edge of a generous margin around the canvas
        let limit = Double(max(drawable.x, drawable.y)) * 4
        points = orbit.map { z in
            let p = view.pixel(of: PlanePoint(Double(z.x), Double(z.y)), width: drawable.x, height: drawable.y, flipY: flipY)
            return CGPoint(x: min(max(p.x, -limit), limit) / scale, y: min(max(p.y, -limit), limit) / scale)
        }
        pointer = CGPoint(x: pixel.x / scale, y: pixel.y / scale)
        if orbit.count < length {
            summary = "Escapes after \(orbit.count - 1) iterations"
        } else if let last = orbit.last,
                  let period = (1...32).first(where: { simd_distance(last, orbit[orbit.count - 1 - $0]) < 1e-4 }) {
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
            Canvas { context, _ in
                let points = orbit.points
                // later points fade, so the path's direction shows
                func fade(_ i: Int) -> Double { 0.25 + 0.75 * pow(0.985, Double(i)) }
                for i in 1..<max(points.count, 1) {
                    var segment = Path()
                    segment.move(to: points[i - 1])
                    segment.addLine(to: points[i])
                    context.stroke(segment, with: .color(.white.opacity(fade(i))), lineWidth: 1.2)
                }
                for (i, point) in points.enumerated() {
                    let r = i == 0 ? 4.0 : 2.2
                    context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(i == 0 ? .orange : .white.opacity(fade(i))))
                }
            }
            GeometryReader { canvas in
                // beside the pointer: on its left in the right third, above it near the bottom
                let p = orbit.pointer, size = canvas.size
                let right = p.x < size.width * 0.7, below = p.y < size.height - 60
                Text(orbit.summary)
                    .font(.rounded(12, .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .panelGlass(in: Capsule())
                    .fixedSize()
                    .padding(.leading, right ? p.x + 16 : 0)
                    .padding(.trailing, right ? 0 : size.width - p.x + 16)
                    .padding(.top, below ? p.y + 14 : 0)
                    .padding(.bottom, below ? 0 : size.height - p.y + 14)
                    .frame(width: size.width, height: size.height,
                           alignment: Alignment(horizontal: right ? .leading : .trailing, vertical: below ? .top : .bottom))
            }
        }
    }
}
