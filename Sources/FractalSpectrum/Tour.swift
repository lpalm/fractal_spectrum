import Foundation
import FractalKit

/// Human-scale comparisons for magnifications.
enum ScaleFact {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻",
    ]

    /// "10⁹⁹⁸" style power of ten.
    static func power(_ e: Int) -> String {
        "10" + String(String(e).compactMap { superscripts[$0] })
    }

    /// "1.2 × 10³⁰" style magnification.
    static func magnification(_ zoomLog10: Double) -> String {
        if zoomLog10 < 3 { return String(format: "%.0f×", pow(10, zoomLog10)) }
        let e = floor(zoomLog10)
        let m = pow(10, zoomLog10 - e)
        return String(format: "%.1f × ", m) + power(Int(e))
    }

    /// What the view's width would be if the whole set were scaled up to a familiar size.
    static func describe(zoomLog10 z: Double) -> String {
        // full set ≈ 4 units wide
        let objects: [(Double, String)] = [
            (1e-2, "a coin"), (1e-3, "a grain of sand"), (1e-4, "a human hair's width"), (1e-5, "a single cell"),
            (1e-6, "a bacterium"), (1e-7, "a virus"), (1e-9, "a strand of DNA"), (1e-10, "an atom"),
            (1e-14, "an atomic nucleus"), (1e-15, "a proton"),
        ]
        let earth = log10(1.27e7)   // metres
        let viewEarth = earth - z
        if viewEarth > -2 { return "" }
        if viewEarth > -15.5 {
            let best = objects.min { abs(log10($0.0) - viewEarth) < abs(log10($1.0) - viewEarth) }!
            return "If the whole set were as wide as the Earth, this view would be the size of \(best.1)."
        }
        let universe = log10(8.8e26)
        let planck = log10(1.6e-35)
        let viewUniverse = universe - z
        if viewUniverse > planck + 1 {
            let best = objects.min { abs(log10($0.0) - viewUniverse) < abs(log10($1.0) - viewUniverse) }!
            if viewUniverse > -15.5 {
                return "If the whole set spanned the observable universe, this view would be the size of \(best.1)."
            }
            return "If the whole set spanned the observable universe, this view would be \(power(Int(-viewUniverse - 15))) times smaller than a proton."
        }
        let below = Int((planck - viewUniverse).rounded())
        return "Scale the whole set up to the observable universe, and this view is still \(power(below)) times smaller than the Planck length."
    }
}

extension Location {
    /// Stops of the guided tour, in order.
    static let tourIDs = ["seahorse", "galaxy", "crown", "twin", "garden", "ancient", "abyss", "edge", "armada", "dragon",
                          "dragonheart", "rabbit"]
}
