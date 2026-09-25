import AppKit
import FractalKit

/// Development automation: commands posted as distributed notifications named
/// "com.lpalm.spectrum.command" (object = "verb:argument"), used to script and snapshot the app.
@MainActor
final class DevHooks {
    private let model: AppModel
    private var token: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.lpalm.spectrum.command"), object: nil, queue: .main) { [weak self] notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { self?.run(command) }
        }
    }

    private func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "snapshot": snapshot(to: arg, withUI: true)
        case "canvas": snapshot(to: arg, withUI: false)
        case "fly": if let location = Location.all.first(where: { $0.id == arg }) { model.fly(to: location) }
        case "jump":
            if let location = Location.all.first(where: { $0.id == arg }), let view = location.viewport {
                model.formula = location.formula
                if let palette = location.palette { model.color.palette = palette }
                model.renderer.snapColors = true
                model.camera.jump(to: view)
            }
        case "home": model.goHome()
        case "back": model.goBack()
        case "forward": model.goForward()
        case "goto": model.goTo(text: arg.replacingOccurrences(of: "|", with: "\n"))
        case "minibrot": model.findMinibrot()
        case "tour": if arg == "off" { model.stopTour() } else { model.startTour() }
        case "zoom": model.zoomStep(Double(arg) ?? -1)
        case "palette": model.setPalette(Int(arg) ?? 0)
        case "family": if let family = FractalFamily(rawValue: arg) { model.selectFamily(family) }
        case "ui": model.showUI = arg != "off"
        case "help": model.showHelp = arg == "on"
        case "quality": if let quality = Quality(rawValue: arg) { model.quality = quality }
        case "autopilot": model.autopilot = arg == "on"
        case "julia": model.toggleJulia()
        case "iter": model.iter.maxIter = Int(arg) ?? model.iter.maxIter
        case "light": model.color.lightStrength = Double(arg) ?? model.color.lightStrength
        case "density": model.color.density = Double(arg) ?? model.color.density
        case "mapping": model.color.mapping = Int(arg) ?? model.color.mapping
        case "edge": model.color.edgeStrength = Double(arg) ?? model.color.edgeStrength
        case "record":
            // record:on / record:<path> writes frame times as CSV and stops recording
            if arg == "on" {
                model.renderer.resetFrameLog()
                model.renderer.recordFrames = true
            } else {
                model.renderer.recordFrames = false
                let lines = model.renderer.frameLog.map {
                    String(format: "%.4f,%.3f,%.3f,%.5f,%.3f,%.3f", $0.t, $0.gpuMs, $0.scale, $0.log2Radius, $0.pan.x, $0.pan.y)
                }
                try? (["t,gpu_ms,scale,log2r,pan_x,pan_y"] + lines).joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
                let slow = model.renderer.slowFrames.map { String(format: "%.4f,%.1f,%@", $0.t, $0.cpuMs, $0.note) }
                try? slow.joined(separator: "\n").write(toFile: arg + ".slow", atomically: true, encoding: .utf8)
                let passes = model.renderer.passLog.map { String(format: "%.4f,%.2f,%d,%@", $0.t, $0.ms, $0.samples, $0.note) }
                try? passes.joined(separator: "\n").write(toFile: arg + ".passes", atomically: true, encoding: .utf8)
            }
        case "speed": model.pilot.speed = Double(arg) ?? model.pilot.speed
        case "export-image":
            model.export.imageSize = ExportController.imageSizes[0]
            model.export.imageSamples = 4
            model.export.exportImage(model: model, to: URL(fileURLWithPath: arg))
        case "export-video":
            model.export.videoSize = ExportController.videoSizes[0]
            model.export.fps = 30
            model.export.duration = 6
            model.export.videoSamples = 1
            model.export.exportVideo(model: model, to: URL(fileURLWithPath: arg))
        case "export-cancel": model.export.cancel()
        case "movie":
            // movie:<path> records the view to that file; movie:off stops
            if arg == "off" { model.stopRecording() } else { model.startRecording(to: URL(fileURLWithPath: arg)) }
        case "export-status":
            let e = model.export
            try? "running=\(e.running) progress=\(e.progress) status=\(e.status)".write(toFile: arg, atomically: true, encoding: .utf8)
        case "status":
            if let s = model.status {
                let d = model.renderer.drawableSize
                let text = String(format: "zoom=%@ iter=%d fps=%.1f gpu=%.2f stage=%@ samples=%d perturbed=%@ drawable=%dx%d",
                                  s.view.zoomText, s.maxIter, s.fps, s.gpuMs, s.stage.rawValue, s.samples, "\(s.perturbed)", d.x, d.y)
                try? text.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "where": try? model.coordinatesText.write(toFile: arg, atomically: true, encoding: .utf8)
        case "orbit":
            // orbit:x,y shows the orbit at drawable pixel (x, y) as if ⇧ were held there; orbit:off hides it
            let v = arg.split(separator: ",").compactMap { Double($0) }
            let points = NSApp.windows.first { $0.isVisible }?.contentView?.bounds.width ?? 1
            let scale = Double(model.renderer.drawableSize.x) / max(Double(points), 1)
            if v.count == 2 { model.showOrbit(atPixel: SIMD2(v[0], v[1]), scale: scale) } else { model.orbitHover = nil }
        case "hover":
            // hover:x,y,re,im shows the Julia preview as if ⌥ were held at canvas point (x, y); hover:off hides it
            let v = arg.split(separator: ",").compactMap { Double($0) }
            model.juliaHover = v.count == 4 ? JuliaHover(point: CGPoint(x: v[0], y: v[1]), re: v[2], im: v[3]) : nil
        case "windows":
            let lines = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow) frame=\($0.frame) content=\($0.contentView.map { "\(type(of: $0))" } ?? "-")" }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "settled":
            // writes "1" to the given file once the view is fully refined
            waitSettled(then: { try? "1".write(toFile: arg, atomically: true, encoding: .utf8) })
        default: NSLog("DevHooks: unknown command %@", command)
        }
    }

    /// Runs `action` once the view is fully refined, or after 30 s.
    private func waitSettled(then action: @escaping () -> Void, tries: Int = 600) {
        if model.renderer.isSettled || tries == 0 { return action() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitSettled(then: action, tries: tries - 1) }
    }

    /// Saves the canvas, optionally with the interface drawn on top. Glass materials cannot be
    /// captured in-process, so the interface layer is an approximation of what is on screen.
    private func snapshot(to path: String, withUI: Bool) {
        guard let canvas = model.renderer.captureCanvas() else { return }
        var image = canvas
        if withUI, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let content = window.contentView {
            let mtk = content.firstSubview(of: FractalMTKView.self)
            mtk?.isHidden = true
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                mtk?.isHidden = false
                let w = canvas.width, h = canvas.height
                if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                   let ui = rep.cgImage {
                    ctx.draw(canvas, in: CGRect(x: 0, y: 0, width: w, height: h))
                    ctx.draw(ui, in: CGRect(x: 0, y: 0, width: w, height: h))
                    if let composed = ctx.makeImage() { image = composed }
                }
            }
            mtk?.isHidden = false
        }
        try? Engine.writePNG(image, to: URL(fileURLWithPath: path))
    }
}

extension NSView {
    /// The first view of the given type in this view's subtree, depth first.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstSubview(of: type) { return t }
        }
        return nil
    }
}
