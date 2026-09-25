import Foundation
import CFractal

/// Locating minibrots (quadratic Mandelbrot set): period in a view, exact nucleus, size.
public enum Minibrot {
    /// Lowest period of a nucleus whose atom domain meets the disk around `center`; 0 if none.
    public static func period(center: PlanePoint, log2Radius: Double, maxPeriod: Int = 1_000_000) -> Int {
        fs_find_period(center.re.ptr, center.im.ptr, log2Radius, maxPeriod)
    }

    /// Newton-refined nucleus of the given period near `start`.
    public static func nucleus(near start: PlanePoint, period: Int, precision: Int) -> PlanePoint? {
        let re = HPFloat(0, precision: precision), im = HPFloat(0, precision: precision)
        let s = start.withPrecision(precision)
        let steps = fs_find_nucleus(s.re.ptr, s.im.ptr, period, 64, re.ptr, im.ptr)
        return steps > 0 ? PlanePoint(re: re, im: im) : nil
    }

    /// The component is approximately `nucleus + scale * c` for c in the whole set: log2 |scale| (roughly
    /// its radius in the plane), arg scale, and whether it is a minibrot (cardioid) rather than a bulb.
    public static func size(nucleus: PlanePoint, period: Int) -> (log2: Double, angle: Double, cardioid: Bool) {
        var angle = 0.0
        var cardioid: Int32 = 0
        let l = fs_nucleus_size(nucleus.re.ptr, nucleus.im.ptr, period, &angle, &cardioid)
        return (l, angle, cardioid != 0)
    }
}
