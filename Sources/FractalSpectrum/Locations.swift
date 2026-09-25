import Foundation
import FractalKit

/// A curated place worth visiting.
struct Location: Identifiable, Hashable {
    let id: String
    let name: String
    let formula: Formula
    let re: String
    let im: String
    /// log10 of the magnification.
    let zoom: Double
    var rotation: Double = 0
    var palette: Int?
    var maxIter: Int?

    var viewport: Viewport? {
        let prec = max(64, Int(zoom * 3.33) + 96)
        guard let c = PlanePoint(re: re, im: im, precision: prec) else { return nil }
        return Viewport(center: c, log2Radius: 1 - zoom / log10(2.0), rotation: rotation * .pi / 180)
    }

    var depthText: String {
        zoom < 3 ? String(format: "%.0f×", pow(10, zoom)) : String(format: "10^%.0f", zoom)
    }

    static func == (a: Location, b: Location) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension Location {
    static let mandel = Formula()

    static let all: [Location] = [
        Location(id: "seahorse", name: "Seahorse Valley", formula: mandel,
                 re: "-0.7453", im: "0.1127", zoom: 2.2, palette: 0),
        Location(id: "elephant", name: "Elephant Valley", formula: mandel,
                 re: "0.2855", im: "0.0107", zoom: 2.1, palette: 5),
        Location(id: "triple", name: "Triple Spiral", formula: mandel,
                 re: "-0.08825", im: "0.65448", zoom: 2.6, palette: 8),
        Location(id: "mini3", name: "Mini Mandelbrot", formula: mandel,
                 re: "-1.7548776662466927", im: "0", zoom: 1.6, palette: 1),
        Location(id: "seahorse14", name: "Spiral Galaxy", formula: mandel,
                 re: "-0.743643887037158704752191506114774", im: "0.131825904205311970493132056385139",
                 zoom: 14, palette: 0),
        Location(id: "crown30", name: "Seahorse Crown", formula: mandel,
                 re: "-0.743643887037158704752191506114774", im: "0.131825904205311970493132056385139",
                 zoom: 30, palette: 0),
    ]
}
