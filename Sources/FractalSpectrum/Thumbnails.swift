import AppKit
import Observation
import FractalKit

/// Renders small previews of fractal families and locations in the background.
@MainActor @Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "thumbnails", qos: .utility)
    @ObservationIgnored private let engine = Engine()   // own reference store: never disturbs the live view
    @ObservationIgnored private var requested: Set<String> = []

    func image(_ key: String) -> NSImage? { images[key] }

    func request(_ key: String, scene: FractalScene, color: ColorSettings, width: Int = 240, height: Int = 150) {
        guard !requested.contains(key) else { return }
        requested.insert(key)
        let engine = self.engine
        queue.async { [weak self] in
            guard let cg = engine.renderStill(scene: scene, color: color,
                                              options: .init(width: width, height: height, samples: 4)) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
            DispatchQueue.main.async { self?.images[key] = img }
        }
    }

    func requestFamily(_ formula: Formula, color: ColorSettings) {
        var iter = IterationSettings()
        iter.maxIter = 400
        request("family-\(formula.family.rawValue)-\(formula.effectivePower)",
                scene: FractalScene(formula: formula, view: Viewport.home(for: formula), iter: iter), color: color)
    }

    func requestLocation(_ l: Location, color: ColorSettings) {
        guard let v = l.viewport else { return }
        var c = color
        if let p = l.palette { c.palette = p }
        var iter = IterationSettings()
        iter.maxIter = l.maxIter ?? 1000
        request("loc-\(l.id)", scene: FractalScene(formula: l.formula, view: v, iter: iter), color: c)
    }
}
