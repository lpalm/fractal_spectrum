import AppKit
import Observation
import FractalKit

/// Renders small previews of fractal families and locations in the background, cached on disk under
/// a hash of everything that affects them.
@MainActor @Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "thumbnails", qos: .utility)
    @ObservationIgnored private let engine = Engine()   // own reference store: never disturbs the live view
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.lpalm.spectrum/thumbnails", isDirectory: true)

    func image(_ key: String) -> NSImage? { images[key] }

    /// `source` describes the scene and colours (it names the cache file together with the renderer version).
    func request(_ key: String, source: String, scene: FractalScene, color: ColorSettings, width: Int = 240, height: Int = 150) {
        guard !requested.contains(key) else { return }
        requested.insert(key)
        let size = NSSize(width: width / 2, height: height / 2)
        let file = cache.appendingPathComponent("\(key)-\(stableHash("\(renderSignature)|\(source)|\(width)x\(height)")).png")
        if let img = NSImage(contentsOf: file) {
            img.size = size
            images[key] = img
            return
        }
        let engine = self.engine, cache = self.cache
        queue.async { [weak self] in
            guard let cg = engine.renderStill(scene: scene, color: color,
                                              options: .init(width: width, height: height, samples: 4)) else { return }
            // replace this key's files from older versions
            let fm = FileManager.default
            try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? []
            where old.hasPrefix(key + "-") && !old.dropFirst(key.count + 1).contains("-") {
                try? fm.removeItem(at: cache.appendingPathComponent(old))
            }
            try? Engine.writePNG(cg, to: file)
            let img = NSImage(cgImage: cg, size: size)
            DispatchQueue.main.async { self?.images[key] = img }
        }
    }

    func requestFamily(_ formula: Formula, color: ColorSettings) {
        var iter = IterationSettings()
        iter.maxIter = 400
        request("family-\(formula.family.rawValue)-\(formula.effectivePower)", source: Thumbnails.json(formula) + Thumbnails.json(color),
                scene: FractalScene(formula: formula, view: Viewport.home(for: formula), iter: iter), color: color)
    }

    func requestLocation(_ l: Location, color: ColorSettings) {
        guard let v = l.viewport else { return }
        var c = color
        if let p = l.palette { c.palette = p }
        var iter = IterationSettings()
        iter.maxIter = l.maxIter ?? 1000
        request("loc-\(l.id)", source: Thumbnails.json(l) + Thumbnails.json(c),
                scene: FractalScene(formula: l.formula, view: v, iter: iter), color: c)
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
