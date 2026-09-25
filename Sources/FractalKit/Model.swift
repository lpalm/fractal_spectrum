import Foundation
import CFractal

/// Escape-time formula families supported by the kernels.
public enum FractalFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case mandelbrot, tricorn, burningShip, celtic

    public var id: String { rawValue }

    var formulaID: Int32 {
        switch self {
        case .mandelbrot: return Int32(FS_FORMULA_MANDEL)
        case .tricorn: return Int32(FS_FORMULA_TRICORN)
        case .burningShip: return Int32(FS_FORMULA_SHIP)
        case .celtic: return Int32(FS_FORMULA_CELTIC)
        }
    }

    public var displayName: String {
        switch self {
        case .mandelbrot: return "Mandelbrot"
        case .tricorn: return "Tricorn"
        case .burningShip: return "Burning Ship"
        case .celtic: return "Celtic"
        }
    }

    /// The Burning Ship is conventionally drawn with the imaginary axis pointing down.
    public var flipY: Bool { self == .burningShip }
}

/// Formula selection: family, Multibrot power and Julia mode.
public struct Formula: Hashable, Codable, Sendable {
    public var family: FractalFamily = .mandelbrot
    public var power: Int = 2
    public var julia = false
    public var juliaRe: Double = -0.7269
    public var juliaIm: Double = 0.1889

    public init(family: FractalFamily = .mandelbrot, power: Int = 2, julia: Bool = false,
                juliaRe: Double = -0.7269, juliaIm: Double = 0.1889) {
        self.family = family
        self.power = power
        self.julia = julia
        self.juliaRe = juliaRe
        self.juliaIm = juliaIm
    }

    public var effectivePower: Int { family == .mandelbrot ? max(2, min(power, 8)) : 2 }

    public var displayName: String {
        var s = family == .mandelbrot && effectivePower > 2 ? "Multibrot z^\(effectivePower)" : family.displayName
        if julia { s += " Julia" }
        return s
    }

    /// Deepest supported zoom (log2 of the view radius).
    public var minLog2Radius: Double { -60_000 }
}

/// What part of the plane is on screen.
public struct Viewport: @unchecked Sendable {
    public var center: PlanePoint
    /// log2 of half the shorter side of the view in plane units.
    public var log2Radius: Double
    public var rotation: Double

    public init(center: PlanePoint, log2Radius: Double, rotation: Double = 0) {
        self.center = center
        self.log2Radius = log2Radius
        self.rotation = rotation
    }

    public static func home(for formula: Formula) -> Viewport {
        if formula.julia { return Viewport(center: PlanePoint(0, 0), log2Radius: log2(1.5)) }
        switch formula.family {
        case .mandelbrot:
            if formula.effectivePower == 2 { return Viewport(center: PlanePoint(-0.65, 0), log2Radius: log2(1.35)) }
            return Viewport(center: PlanePoint(-0.1, 0), log2Radius: log2(1.45))
        case .tricorn: return Viewport(center: PlanePoint(-0.3, 0), log2Radius: log2(1.6))
        case .burningShip: return Viewport(center: PlanePoint(-0.45, -0.5), log2Radius: log2(1.35))
        case .celtic: return Viewport(center: PlanePoint(-0.35, 0), log2Radius: log2(1.7))
        }
    }

    /// Magnification relative to a view of radius 2.
    public var zoomLog10: Double { (1 - log2Radius) * log10(2.0) }

    public var zoomText: String {
        let l = zoomLog10
        if l < 4 { return String(format: "%.1f×", pow(10, l)) }
        let e = floor(l)
        return String(format: "%.2fe%.0f", pow(10, l - e), e)
    }

    /// Bits of precision needed for positions at this zoom on a `minSide`-sample grid.
    public func requiredPrecision(minSide: Double) -> Int {
        let log2Step = log2Radius + 1 - log2(max(minSide, 1))
        return max(64, Int(-log2Step) + 48)
    }
}

/// Iteration limits and precision/speed trade-offs.
public struct IterationSettings: Codable, Sendable, Hashable {
    public var maxIter: Int = 1500
    public var autoIterations = true
    public var bailout: Double = 256
    /// log2 of the relative error tolerated by bilinear approximation.
    public var blaLog2Eps: Double = -24
    public var useBLA = true
    public var derivative = true

    public init() {}
}

/// How iteration data becomes colour.
public struct ColorSettings: Codable, Sendable, Hashable {
    public var palette = 0
    public var density: Double = 0.42
    public var offset: Double = 0.0
    /// 0 linear, 1 square root, 2 logarithmic, 3 distance to the set.
    public var mapping = 2
    public var lightStrength: Double = 0.75
    public var lightAzimuth: Double = 2.3
    public var lightElevation: Double = 0.75
    public var edgeStrength: Double = 0.35
    public var interior = SIMD3<Float>(0.004, 0.004, 0.008)

    public init() {}
}

/// Everything needed to compute one image.
public struct FractalScene: @unchecked Sendable {
    public var formula: Formula
    public var view: Viewport
    public var iter: IterationSettings

    public init(formula: Formula, view: Viewport, iter: IterationSettings) {
        self.formula = formula
        self.view = view
        self.iter = iter
    }
}
