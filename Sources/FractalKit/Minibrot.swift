import Foundation
import CFractal

/// Locating minibrots (quadratic Mandelbrot set): period in a view, exact nucleus, size and shape.
public enum Minibrot {
    /// A located component: its nucleus and period, log2 of its size (roughly its radius), its rotation
    /// relative to the whole set, and whether it is a minibrot (cardioid) rather than a bulb (disc).
    public struct Found: @unchecked Sendable {
        public let nucleus: PlanePoint
        public let period: Int
        public let log2Size: Double
        public let angle: Double
        public let cardioid: Bool
    }

    /// Lowest period of a nucleus whose atom domain meets the disk around `center`; 0 if none.
    public static func period(center: PlanePoint, log2Radius: Double, maxPeriod: Int = 1_000_000) -> Int {
        fs_find_period(center.re.handle, center.im.handle, log2Radius, maxPeriod)
    }

    /// Newton-refined nucleus of the given period near `start`.
    public static func nucleus(near start: PlanePoint, period: Int, precision: Int) -> PlanePoint? {
        let re = HPFloat(0, precision: precision), im = HPFloat(0, precision: precision)
        let start = start.withPrecision(precision)
        let steps = fs_find_nucleus(start.re.handle, start.im.handle, period, 64, re.handle, im.handle)
        return steps > 0 ? PlanePoint(re: re, im: im) : nil
    }

    /// The component is approximately `nucleus + scale * c` for c in the whole set: log2 |scale| (roughly
    /// its radius in the plane), arg scale, and whether it is a minibrot (cardioid) rather than a bulb.
    public static func size(nucleus: PlanePoint, period: Int) -> (log2: Double, angle: Double, cardioid: Bool) {
        var angle = 0.0
        var cardioid: Int32 = 0
        let log2Size = fs_nucleus_size(nucleus.re.handle, nucleus.im.handle, period, &angle, &cardioid)
        return (log2Size, angle, cardioid != 0)
    }

    /// The lowest-period component whose atom domain meets the disk of radius 2^searchLog2Radius around
    /// `center`, located to the precision a view of radius 2^viewLog2Radius needs; nil if none is found.
    public static func locate(near center: PlanePoint, searchLog2Radius: Double, viewLog2Radius: Double,
                              maxPeriod: Int) -> Found? {
        let period = period(center: center, log2Radius: searchLog2Radius, maxPeriod: maxPeriod)
        guard period > 0 else { return nil }
        // Newton's method needs about twice the digits of the view to converge on the nucleus
        let precision = max(center.precision, Int(-viewLog2Radius) * 2 + 160)
        guard let nucleus = nucleus(near: center, period: period, precision: precision) else { return nil }
        let (log2Size, angle, cardioid) = size(nucleus: nucleus, period: period)
        return Found(nucleus: nucleus, period: period, log2Size: log2Size, angle: angle, cardioid: cardioid)
    }
}
