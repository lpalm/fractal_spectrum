import Foundation
import CFractal

/// Immutable arbitrary-precision real number (MPFR). Operations return new values.
public final class HPFloat: @unchecked Sendable {
    let ptr: OpaquePointer

    private init(ptr: OpaquePointer) { self.ptr = ptr }

    public convenience init(_ value: Double, precision: Int = 64) {
        self.init(ptr: fs_hp_new(precision))
        fs_hp_set_d(ptr, value)
    }

    public convenience init?(_ text: String, precision: Int) {
        self.init(ptr: fs_hp_new(precision))
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || fs_hp_set_str(ptr, trimmed) != 0 { return nil }
    }

    deinit { fs_hp_free(ptr) }

    public var precision: Int { fs_hp_prec(ptr) }

    public var doubleValue: Double { fs_hp_get_d(ptr) }

    /// Same value at a different precision.
    public func withPrecision(_ bits: Int) -> HPFloat {
        HPFloat(ptr: fs_hp_clone(ptr, bits))
    }

    /// self + m * 2^e at `precision` bits (defaults to the current precision).
    public func adding(_ m: Double, exp e: Int, precision: Int? = nil) -> HPFloat {
        let r = fs_hp_clone(ptr, precision ?? self.precision)!
        fs_hp_add_2exp(r, m, e)
        return HPFloat(ptr: r)
    }

    public func adding(_ x: FloatExp, precision: Int? = nil) -> HPFloat {
        adding(x.m, exp: x.e, precision: precision)
    }

    /// self - other in extended range.
    public func minus(_ other: HPFloat) -> FloatExp {
        var e = 0
        let m = fs_hp_diff_2exp(ptr, other.ptr, &e)
        return FloatExp(m, e)
    }

    /// self + (other - self) * t at `precision` bits.
    public func lerp(to other: HPFloat, _ t: Double, precision: Int) -> HPFloat {
        let r = fs_hp_new(precision)!
        fs_hp_lerp(r, ptr, other.ptr, t)
        return HPFloat(ptr: r)
    }

    /// Scientific notation with `digits` significant digits.
    public func string(digits: Int) -> String {
        guard let c = fs_hp_to_str(ptr, Int32(max(digits, 1))) else { return "0" }
        defer { fs_free(c) }
        return String(cString: c)
    }

}

/// Point in the complex plane at arbitrary precision.
public struct PlanePoint: @unchecked Sendable {
    public var re: HPFloat
    public var im: HPFloat

    public init(re: HPFloat, im: HPFloat) {
        self.re = re
        self.im = im
    }

    public init(_ re: Double, _ im: Double, precision: Int = 64) {
        self.re = HPFloat(re, precision: precision)
        self.im = HPFloat(im, precision: precision)
    }

    public init?(re: String, im: String, precision: Int) {
        guard let r = HPFloat(re, precision: precision), let i = HPFloat(im, precision: precision) else { return nil }
        self.re = r
        self.im = i
    }

    public var precision: Int { max(re.precision, im.precision) }

    public func withPrecision(_ bits: Int) -> PlanePoint {
        PlanePoint(re: re.withPrecision(bits), im: im.withPrecision(bits))
    }

    public func offset(by d: ComplexExp, precision: Int? = nil) -> PlanePoint {
        PlanePoint(re: re.adding(d.re, precision: precision), im: im.adding(d.im, precision: precision))
    }

    /// self - other.
    public func minus(_ other: PlanePoint) -> ComplexExp {
        ComplexExp(re: re.minus(other.re), im: im.minus(other.im))
    }

    public func lerp(to other: PlanePoint, _ t: Double, precision: Int) -> PlanePoint {
        PlanePoint(re: re.lerp(to: other.re, t, precision: precision), im: im.lerp(to: other.im, t, precision: precision))
    }
}

/// Real number m * 2^e with a double mantissa, for host-side extended-range arithmetic.
public struct FloatExp: Sendable, CustomStringConvertible {
    public var m: Double
    public var e: Int

    public init(_ m: Double, _ e: Int = 0) {
        if m == 0 || !m.isFinite {
            self.m = m.isFinite ? 0 : m
            self.e = 0
        } else {
            // Swift's frexp overload drops the sign, so normalise by hand.
            let k = Int(m.exponent) + 1
            self.m = scalbn(m, -k)
            self.e = k + e
        }
    }

    public static let zero = FloatExp(0)

    /// log2 |value|; -infinity for zero.
    public var log2Abs: Double { m == 0 ? -.infinity : log2(abs(m)) + Double(e) }

    public static func fromLog2(_ l: Double, sign: Double = 1) -> FloatExp {
        guard l.isFinite else { return .zero }
        let i = floor(l)
        return FloatExp(sign * exp2(l - i), Int(i))
    }

    public static func + (a: FloatExp, b: FloatExp) -> FloatExp {
        if a.m == 0 { return b }
        if b.m == 0 { return a }
        let e = max(a.e, b.e)
        return FloatExp(scalbn(a.m, a.e - e) + scalbn(b.m, b.e - e), e)
    }

    public static prefix func - (a: FloatExp) -> FloatExp { FloatExp(-a.m, a.e) }
    public static func - (a: FloatExp, b: FloatExp) -> FloatExp { a + (-b) }
    public static func * (a: FloatExp, b: FloatExp) -> FloatExp { FloatExp(a.m * b.m, a.e + b.e) }
    public static func * (a: FloatExp, b: Double) -> FloatExp { FloatExp(a.m * b, a.e) }

    /// Value as a Double (0 or infinity outside the representable range).
    public var double: Double { scalbn(m, e) }

    public var description: String {
        if m == 0 { return "0" }
        let (mant, ex) = scientific(log10: log2Abs * log10(2.0), digits: 4)
        return String(format: "%.4fe%+d", m < 0 ? -mant : mant, ex)
    }
}

/// Exponent the kernels use for exact zeros (FS_ZERO_EXP in ShaderTypes.h).
let zeroExponent: Int32 = -(1 << 24)

/// Complex number with extended-range components.
public struct ComplexExp: Sendable {
    public var re: FloatExp
    public var im: FloatExp

    public init(re: FloatExp, im: FloatExp) {
        self.re = re
        self.im = im
    }

    public static let zero = ComplexExp(re: .zero, im: .zero)

    public var log2Abs: Double {
        let e = max(re.m == 0 ? Int.min / 4 : re.e, im.m == 0 ? Int.min / 4 : im.e)
        if re.m == 0 && im.m == 0 { return -.infinity }
        let x = scalbn(re.m, re.e - e), y = scalbn(im.m, im.e - e)
        return 0.5 * log2(x * x + y * y) + Double(e)
    }

    /// Shared-exponent float mantissas (value = m * 2^e) as used by the kernels.
    public var shared: (m: SIMD2<Float>, e: Int32) {
        if re.m == 0 && im.m == 0 { return (SIMD2(0, 0), zeroExponent) }
        let e = max(re.m == 0 ? Int.min / 4 : re.e, im.m == 0 ? Int.min / 4 : im.e)
        let x = scalbn(re.m, re.e - e), y = scalbn(im.m, im.e - e)
        return (SIMD2(Float(x), Float(y)), Int32(clamping: e))
    }

    public static func + (a: ComplexExp, b: ComplexExp) -> ComplexExp {
        ComplexExp(re: a.re + b.re, im: a.im + b.im)
    }

    public static func * (a: ComplexExp, b: Double) -> ComplexExp {
        ComplexExp(re: a.re * b, im: a.im * b)
    }
}
