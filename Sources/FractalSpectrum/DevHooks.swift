import AppKit
import FractalKit

/// Development automation: commands posted as distributed notifications named
/// "com.lpalm.spectrum.command" (object = "verb:argument"), used to script and snapshot the app.
@MainActor
final class DevHooks {
    private let model: AppModel
    private var observer: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.lpalm.spectrum.command"), object: nil, queue: .main) { [weak self] notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated { self?.run(command) }
        }
    }

    private func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "snapshot": snapshot(to: argument, withUI: true)
        case "canvas": snapshot(to: argument, withUI: false)
        case "fly": if let location = Location.all.first(where: { $0.id == argument }) { model.fly(to: location) }
        case "jump":
            if let location = Location.all.first(where: { $0.id == argument }), let view = location.viewport {
                model.formula = location.formula
                if let palette = location.palette { model.color.palette = palette }
                model.renderer.snapColors = true
                model.camera.jump(to: view)
            }
        case "home": model.goHome()
        case "back": model.goBack()
        case "forward": model.goForward()
        case "goto": model.goTo(text: argument.replacingOccurrences(of: "|", with: "\n"))
        case "minibrot": model.findMinibrot()
        case "tour": if argument == "off" { model.stopTour() } else { model.startTour() }
        case "zoom": model.zoomStep(Double(argument) ?? -1)
        case "palette": model.setPalette(Int(argument) ?? 0)
        case "family": if let family = FractalFamily(rawValue: argument) { model.selectFamily(family) }
        case "ui": model.showUI = argument != "off"
        case "help": model.showHelp = argument == "on"
        case "quality": if let quality = Quality(rawValue: argument) { model.quality = quality }
        case "autopilot": model.autopilotEngaged = argument == "on"
        case "julia": model.toggleJulia()
        case "iter": model.iteration.maxIter = Int(argument) ?? model.iteration.maxIter
        case "light": model.color.lightStrength = Double(argument) ?? model.color.lightStrength
        case "density": model.color.density = Double(argument) ?? model.color.density
        case "mapping": model.color.mapping = Int(argument) ?? model.color.mapping
        case "edge": model.color.edgeStrength = Double(argument) ?? model.color.edgeStrength
        case "record":
            // record:on / record:<path> writes frame times as CSV and stops recording
            if argument == "on" {
                model.renderer.resetFrameLog()
                model.renderer.recordFrames = true
            } else {
                model.renderer.recordFrames = false
                let lines = model.renderer.frameLog.map {
                    String(format: "%.4f,%.3f,%.3f,%.5f,%.3f,%.3f", $0.t, $0.gpuMs, $0.scale, $0.log2Radius, $0.pan.x, $0.pan.y)
                }
                try? (["t,gpu_ms,scale,log2r,pan_x,pan_y"] + lines).joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
                let slow = model.renderer.slowFrames.map { String(format: "%.4f,%.1f,%@", $0.t, $0.cpuMs, $0.note) }
                try? slow.joined(separator: "\n").write(toFile: argument + ".slow", atomically: true, encoding: .utf8)
                let passes = model.renderer.passLog.map { String(format: "%.4f,%.2f,%d,%@", $0.t, $0.ms, $0.samples, $0.note) }
                try? passes.joined(separator: "\n").write(toFile: argument + ".passes", atomically: true, encoding: .utf8)
            }
        case "speed": model.autopilot.speed = Double(argument) ?? model.autopilot.speed
        case "export-image":
            // export-image:<path> renders a quick 4K image there; export-image: saves one to the image
            // folder as set up in the export sheet
            var job = model.export.imageJob(model: model)
            guard !argument.isEmpty else { return model.export.render(job) }
            (job.width, job.height, job.samples) = (3840, 2160, 4)
            model.export.render(job, to: URL(fileURLWithPath: argument))
        case "export-video":
            // export-video:<path> renders a quick 6-second 1080p HEVC video there
            var job = model.export.videoJob(model: model)
            (job.width, job.height, job.fps, job.duration, job.samples) = (1920, 1080, 30, 6, 1)
            (job.codec, job.spin, job.colorCycle) = (.hevc, 0, 0)
            model.export.render(job, to: URL(fileURLWithPath: argument))
        case "export-cancel": model.export.cancel()
        case "export-sheet":
            // export-sheet:image / export-sheet:video opens the export sheet; export-sheet:off closes it
            if let kind = ExportController.Kind.allCases.first(where: { $0.rawValue.lowercased() == argument }) {
                model.openExport(kind)
            } else {
                model.showExport = false
            }
        case "sheet":
            // sheet:<path> saves the open sheet (e.g. the export settings) as an image
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }), let content = sheet.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let image = bitmap.cgImage { try? Engine.writePNG(image, to: URL(fileURLWithPath: argument)) }
            }
        case "movie":
            // movie:<path> records the view to that file, movie: to the video folder; movie:off stops
            if argument == "off" {
                model.stopRecording()
            } else {
                model.startRecording(to: argument.isEmpty ? nil : URL(fileURLWithPath: argument))
            }
        case "export-status":
            let export = model.export
            try? "running=\(export.running) progress=\(export.progress) status=\(export.status)"
                .write(toFile: argument, atomically: true, encoding: .utf8)
        case "status":
            if let status = model.status {
                let size = model.renderer.drawableSize
                let text = String(format: "zoom=%@ iter=%d fps=%.1f gpu=%.2f stage=%@ samples=%d perturbed=%@ drawable=%dx%d",
                                  status.view.zoomText, status.maxIter, status.fps, status.gpuMs, status.stage.rawValue,
                                  status.samples, "\(status.perturbed)", size.x, size.y)
                try? text.write(toFile: argument, atomically: true, encoding: .utf8)
            }
        case "where": try? model.coordinatesText.write(toFile: argument, atomically: true, encoding: .utf8)
        case "orbit":
            // orbit:x,y shows the orbit at drawable pixel (x, y) as if ⇧ were held there; orbit:off hides it
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            let widthInPoints = NSApp.windows.first { $0.isVisible }?.contentView?.bounds.width ?? 1
            let scale = Double(model.renderer.drawableSize.x) / max(Double(widthInPoints), 1)
            if numbers.count == 2 {
                model.showOrbit(atPixel: SIMD2(numbers[0], numbers[1]), scale: scale)
            } else {
                model.orbitHover = nil
            }
        case "hover":
            // hover:x,y,re,im shows the Julia preview as if ⌥ were held at canvas point (x, y); hover:off hides it
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            model.juliaHover = numbers.count == 4
                ? JuliaHover(point: CGPoint(x: numbers[0], y: numbers[1]), re: numbers[2], im: numbers[3]) : nil
        case "windows":
            let lines = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow) frame=\($0.frame) content=\($0.contentView.map { "\(type(of: $0))" } ?? "-")" }
            try? lines.joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
        case "settled":
            // writes "1" to the given file once the view is fully refined
            waitSettled(then: { try? "1".write(toFile: argument, atomically: true, encoding: .utf8) })
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
            let canvasView = content.firstSubview(of: FractalMTKView.self)
            canvasView?.isHidden = true
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                canvasView?.isHidden = false
                let w = canvas.width, h = canvas.height
                if let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                   let interface = bitmap.cgImage {
                    context.draw(canvas, in: CGRect(x: 0, y: 0, width: w, height: h))
                    context.draw(interface, in: CGRect(x: 0, y: 0, width: w, height: h))
                    if let composed = context.makeImage() { image = composed }
                }
            }
            canvasView?.isHidden = false
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
