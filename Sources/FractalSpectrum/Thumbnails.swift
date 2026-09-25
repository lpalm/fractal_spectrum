import AppKit
import Observation
import FractalKit

/// Renders small previews of fractal families and places in the background, cached on disk under a
/// hash of everything that affects them.
@MainActor @Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "thumbnails", qos: .utility)
    @ObservationIgnored private let engine = Engine()   // own reference store: never disturbs the live view
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.lpalm.spectrum/thumbnails", isDirectory: true)

    /// Each family's tile shows it in its own palette.
    private static let familyPalettes: [FractalFamily: Int] = [.mandelbrot: 0, .tricorn: 4, .burningShip: 7, .celtic: 2]

    func image(for family: FractalFamily) -> NSImage? { images[Thumbnails.key(for: family)] }
    func image(for location: Location) -> NSImage? { images[Thumbnails.key(for: location)] }

    private static func key(for family: FractalFamily) -> String { "family-\(family.rawValue)" }
    private static func key(for location: Location) -> String { "loc-\(location.id)" }

    /// Starts on the tiles of every family and curated place.
    func requestAll() {
        for family in FractalFamily.allCases { requestFamily(family) }
        for location in Location.all { requestLocation(location, color: ColorSettings()) }
    }

    func requestFamily(_ family: FractalFamily) {
        let formula = Formula(family: family)
        var color = ColorSettings()
        color.palette = Thumbnails.familyPalettes[family] ?? 0
        var iteration = IterationSettings()
        iteration.maxIter = 400
        request(Thumbnails.key(for: family), source: Thumbnails.json(formula) + Thumbnails.json(color),
                scene: FractalScene(formula: formula, view: Viewport.home(for: formula), iteration: iteration), color: color)
    }

    /// A place's tile, in its own palette if it has one.
    func requestLocation(_ location: Location, color: ColorSettings) {
        guard let view = location.viewport else { return }
        var color = color
        if let palette = location.palette { color.palette = palette }
        var iteration = IterationSettings()
        iteration.maxIter = location.maxIter ?? 1000
        request(Thumbnails.key(for: location), source: Thumbnails.json(location) + Thumbnails.json(color),
                scene: FractalScene(formula: location.formula, view: view, iteration: iteration), color: color)
    }

    /// `source` describes the scene and colours (it names the cache file together with the renderer version).
    private func request(_ key: String, source: String, scene: FractalScene, color: ColorSettings,
                         width: Int = 240, height: Int = 150) {
        guard requested.insert(key).inserted else { return }
        let size = NSSize(width: width / 2, height: height / 2)
        let file = cache.appendingPathComponent("\(key)-\(stableHash("\(renderSignature)|\(source)|\(width)x\(height)")).png")
        if let image = NSImage(contentsOf: file) {
            image.size = size
            images[key] = image
            return
        }
        let engine = self.engine, cache = self.cache
        queue.async { [weak self] in
            guard let rendered = engine.renderStill(scene: scene, color: color,
                                                    options: .init(width: width, height: height, samples: 4)) else { return }
            // replace this key's files from older versions
            let files = FileManager.default
            try? files.createDirectory(at: cache, withIntermediateDirectories: true)
            for old in (try? files.contentsOfDirectory(atPath: cache.path)) ?? []
            where old.hasPrefix(key + "-") && !old.dropFirst(key.count + 1).contains("-") {
                try? files.removeItem(at: cache.appendingPathComponent(old))
            }
            try? Engine.writePNG(rendered, to: file)
            let image = NSImage(cgImage: rendered, size: size)
            DispatchQueue.main.async { self?.images[key] = image }
        }
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
