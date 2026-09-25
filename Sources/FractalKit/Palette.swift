import Foundation
import Metal

/// A cyclic colour gradient defined by sRGB stops, interpolated smoothly in OKLab.
/// FNV-1a hash in hexadecimal: stable across launches, unlike `hashValue`.
public func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        h ^= UInt64(b)
        h &*= 0x100000001b3
    }
    return String(h, radix: 16)
}

/// Changes whenever the kernels or palettes do: a version for caches of rendered images.
public let renderSignature = stableHash(fractalShaderSource + Palette.all.map { "\($0.id)\($0.stops)" }.joined())

public struct Palette: Sendable, Identifiable {
    public let id: Int
    public let name: String
    /// Positions in [0, 1) with sRGB colours in 0...255.
    let stops: [(Double, SIMD3<Double>)]

    public static let all: [Palette] = [
        Palette(id: 0, name: "Classic", stops: [
            (0.0, [0, 7, 100]), (0.16, [32, 107, 203]), (0.42, [237, 255, 255]),
            (0.6425, [255, 170, 0]), (0.8575, [0, 2, 0]),
        ]),
        Palette(id: 1, name: "Inferno", stops: [
            (0.0, [3, 1, 10]), (0.18, [60, 12, 96]), (0.36, [170, 40, 88]), (0.52, [240, 110, 30]),
            (0.66, [252, 220, 120]), (0.76, [255, 250, 225]), (0.88, [120, 30, 60]),
        ]),
        Palette(id: 2, name: "Glacier", stops: [
            (0.0, [2, 8, 26]), (0.2, [18, 52, 108]), (0.42, [48, 130, 190]), (0.6, [150, 215, 235]),
            (0.72, [242, 252, 255]), (0.86, [70, 120, 170]),
        ]),
        Palette(id: 3, name: "Neon", stops: [
            (0.0, [6, 0, 18]), (0.16, [110, 10, 150]), (0.32, [245, 40, 170]), (0.46, [255, 170, 230]),
            (0.58, [40, 220, 255]), (0.74, [20, 70, 220]), (0.88, [30, 6, 70]),
        ]),
        Palette(id: 4, name: "Sunset", stops: [
            (0.0, [18, 6, 40]), (0.18, [100, 22, 96]), (0.36, [215, 60, 90]), (0.52, [250, 140, 70]),
            (0.66, [255, 225, 150]), (0.8, [150, 80, 140]), (0.92, [50, 20, 80]),
        ]),
        Palette(id: 5, name: "Emerald", stops: [
            (0.0, [0, 14, 12]), (0.2, [0, 80, 64]), (0.4, [30, 170, 120]), (0.56, [210, 240, 170]),
            (0.68, [235, 190, 60]), (0.84, [80, 50, 12]),
        ]),
        Palette(id: 6, name: "Ink", stops: [
            (0.0, [8, 9, 12]), (0.3, [70, 72, 80]), (0.5, [236, 232, 222]), (0.62, [255, 252, 245]),
            (0.8, [120, 118, 112]),
        ]),
        Palette(id: 7, name: "Copper", stops: [
            (0.0, [10, 6, 4]), (0.22, [90, 36, 16]), (0.42, [200, 110, 60]), (0.56, [250, 210, 160]),
            (0.66, [120, 200, 200]), (0.8, [30, 70, 80]),
        ]),
        Palette(id: 8, name: "Twilight", stops: [
            (0.0, [14, 8, 36]), (0.2, [66, 48, 146]), (0.4, [190, 120, 200]), (0.55, [252, 226, 236]),
            (0.7, [100, 176, 206]), (0.86, [30, 60, 110]),
        ]),
        Palette.spectrum(id: 9),
    ]

    init(id: Int, name: String, stops: [(Double, SIMD3<Double>)]) {
        self.id = id
        self.name = name
        self.stops = stops
    }

    private static func spectrum(id: Int) -> Palette {
        let stops = (0..<12).map { i -> (Double, SIMD3<Double>) in
            let h = Double(i) / 12 * 2 * .pi
            let lab = SIMD3(0.74, 0.14 * cos(h), 0.14 * sin(h))
            return (Double(i) / 12, OKLab.toSRGB255(lab))
        }
        return Palette(id: id, name: "Spectrum", stops: stops)
    }

    /// Linear-light RGB samples of the full cycle.
    public func samples(_ n: Int) -> [SIMD3<Float>] {
        let labs = stops.map { OKLab.fromSRGB255($0.1) }
        let pos = stops.map { $0.0 }
        let k = stops.count
        return (0..<n).map { i in
            let t = Double(i) / Double(n)
            var j = k - 1
            for s in 0..<k where pos[s] <= t { j = s }
            let j1 = (j + 1) % k
            let t0 = pos[j]
            let t1 = j1 == 0 ? 1.0 + pos[0] : pos[j1]
            let u = (t - t0) / max(t1 - t0, 1e-9)
            // Catmull-Rom through neighbouring stops, cyclic
            let p0 = labs[(j + k - 1) % k], p1 = labs[j], p2 = labs[j1], p3 = labs[(j + 2) % k]
            let u2 = u * u, u3 = u2 * u
            var lab = 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (3 * p1 - p0 - 3 * p2 + p3) * u3)
            lab.x = min(max(lab.x, 0), 1)
            let rgb = OKLab.toLinear(lab)
            return SIMD3<Float>(Float(min(max(rgb.x, 0), 1)), Float(min(max(rgb.y, 0), 1)), Float(min(max(rgb.z, 0), 1)))
        }
    }
}

enum OKLab {
    static func srgbToLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func linearToSrgb(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func fromLinear(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func toLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func fromSRGB255(_ c: SIMD3<Double>) -> SIMD3<Double> {
        fromLinear(SIMD3(srgbToLinear(c.x / 255), srgbToLinear(c.y / 255), srgbToLinear(c.z / 255)))
    }

    static func toSRGB255(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = toLinear(lab)
        return SIMD3(linearToSrgb(min(max(l.x, 0), 1)), linearToSrgb(min(max(l.y, 0), 1)), linearToSrgb(min(max(l.z, 0), 1))) * 255
    }
}

/// All palettes packed into one texture, one row each.
public final class PaletteBank: @unchecked Sendable {
    public static let width = 1024
    public let texture: MTLTexture
    public var count: Int { Palette.all.count }

    public init(device: MTLDevice) {
        let w = PaletteBank.width, h = Palette.all.count
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        texture = device.makeTexture(descriptor: desc)!
        for p in Palette.all {
            let row = p.samples(w).flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16(1)] }
            row.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, p.id, w, 1), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: w * 8)
            }
        }
    }

    /// sRGB preview colours for UI swatches.
    public static func swatch(_ palette: Palette, count: Int) -> [SIMD3<Double>] {
        palette.samples(count).map {
            SIMD3(OKLab.linearToSrgb(Double($0.x)), OKLab.linearToSrgb(Double($0.y)), OKLab.linearToSrgb(Double($0.z)))
        }
    }
}
