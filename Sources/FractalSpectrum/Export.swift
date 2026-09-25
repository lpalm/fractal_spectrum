import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import FractalKit

/// Image and video export settings plus the progress of a running export.
@MainActor @Observable
final class ExportController {
    enum Kind: String, CaseIterable, Identifiable {
        case image = "Image", video = "Video"
        var id: String { rawValue }
    }

    struct Size: Hashable, Identifiable {
        let name: String
        let width: Int
        let height: Int
        var id: String { name }
        var label: String { "\(name) · \(width)×\(height)" }
    }

    static let imageSizes: [Size] = [
        Size(name: "4K UHD", width: 3840, height: 2160),
        Size(name: "5K", width: 5120, height: 2880),
        Size(name: "8K UHD", width: 7680, height: 4320),
        Size(name: "16K", width: 15360, height: 8640),
        Size(name: "Square 8K", width: 8192, height: 8192),
        Size(name: "Poster 12K", width: 9000, height: 12000),
    ]

    static let videoSizes: [Size] = [
        Size(name: "1080p", width: 1920, height: 1080),
        Size(name: "1440p", width: 2560, height: 1440),
        Size(name: "4K UHD", width: 3840, height: 2160),
        Size(name: "Vertical 1080×1920", width: 1080, height: 1920),
    ]

    var kind = Kind.image
    var imageSize = ExportController.imageSizes[0]
    var imageSamples = 16
    var videoSize = ExportController.videoSizes[0]
    var fps = 60
    var duration = 20.0
    var videoSamples = 4
    var codec = Exporter.Codec.hevc
    var spin = 0.0
    var cycleColors = false

    // Running export
    var running = false
    var progress = 0.0
    var preview: NSImage?
    var status = ""
    var lastOutput: URL?
    /// Called once when the running export ends.
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private let cancelToken = CancelToken()
    @ObservationIgnored private var started = Date()

    func cancel() { cancelToken.cancelled = true }

    var eta: String {
        guard running, progress > 0.02 else { return "" }
        let elapsed = Date().timeIntervalSince(started)
        let left = elapsed / progress * (1 - progress)
        if left < 60 { return String(format: "%.0f s left", left) }
        return String(format: "%.0f min left", left / 60)
    }

    /// Suggested video length: about one doubling of zoom per ~0.45 s, clamped to 10 s…5 min.
    static func suggestedDuration(for view: Viewport, from start: Viewport) -> Double {
        let doublings = max(start.log2Radius - view.log2Radius, 1)
        return min(300, max(10, (doublings * 0.45).rounded()))
    }

    private static func askForURL(type: UTType, ext: String, in dir: FileManager.SearchPathDirectory) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = defaultName("Spectrum", ext)
        panel.directoryURL = FileManager.default.urls(for: dir, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func defaultName(_ prefix: String, _ ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(f.string(from: Date())).\(ext)"
    }

    func exportImage(model: AppModel, to preset: URL? = nil) {
        guard let url = preset ?? ExportController.askForURL(type: .png, ext: "png", in: .picturesDirectory) else { return }
        var iter = model.iter
        iter.maxIter = max(iter.maxIter, 1000)
        let job = Exporter.ImageJob(scene: FractalScene(formula: model.formula, view: model.camera.view, iter: iter),
                                    color: model.color, width: imageSize.width, height: imageSize.height,
                                    samples: imageSamples)
        begin("Rendering \(imageSize.width)×\(imageSize.height)")
        let token = cancelToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let exporter = Exporter()
            do {
                try exporter.exportImage(job, to: url) { p in
                    DispatchQueue.main.async { self?.progress = p }
                    return !token.cancelled
                }
                await self?.finish(url: url, message: "Saved \(url.lastPathComponent)")
            } catch {
                await self?.finish(url: nil, message: token.cancelled ? "Cancelled" : "Export failed: \(error.localizedDescription)")
            }
        }
    }

    func exportVideo(model: AppModel, to preset: URL? = nil) {
        guard let url = preset ?? ExportController.askForURL(type: codec == .prores ? .quickTimeMovie : .mpeg4Movie,
                                                             ext: codec == .prores ? "mov" : "mp4",
                                                             in: .moviesDirectory) else { return }
        let job = Exporter.VideoJob(formula: model.formula, target: model.camera.view,
                                    start: Viewport.home(for: model.formula), color: model.color, colorStats: nil,
                                    width: videoSize.width, height: videoSize.height, fps: fps, duration: duration,
                                    samples: videoSamples, codec: codec, spin: spin, colorCycle: cycleColors ? 0.05 : 0)
        begin("Rendering \(job.frameCount) frames")
        let token = cancelToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let exporter = Exporter()
            do {
                try exporter.exportVideo(job, to: url) { p, img in
                    DispatchQueue.main.async {
                        self?.progress = p
                        if let img { self?.preview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)) }
                    }
                    return !token.cancelled
                }
                await self?.finish(url: url, message: "Saved \(url.lastPathComponent)")
            } catch {
                await self?.finish(url: nil, message: token.cancelled ? "Cancelled" : "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func begin(_ text: String) {
        cancelToken.cancelled = false
        running = true
        progress = 0
        preview = nil
        status = text
        started = Date()
    }

    private func finish(url: URL?, message: String) {
        running = false
        status = message
        if let url { lastOutput = url }
        onFinish?()
        onFinish = nil
    }
}

/// Export sheet: image and zoom-video settings with live progress.
struct ExportSheet: View {
    @Bindable var model: AppModel
    @Bindable var export: ExportController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Export")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Picker("", selection: $export.kind) {
                    ForEach(ExportController.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(export.running)
            }
            if export.kind == .image { imageSettings } else { videoSettings }
            if export.running || export.lastOutput != nil || !export.status.isEmpty { progressView }
            HStack {
                Text(summary)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(export.kind == .image ? "Save Image…" : "Render Video…") {
                    if export.kind == .image { export.exportImage(model: model) } else { export.exportVideo(model: model) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(export.running)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            export.duration = ExportController.suggestedDuration(for: model.camera.view, from: Viewport.home(for: model.formula))
        }
    }

    private var summary: String {
        let v = model.camera.view
        if export.kind == .image {
            let mp = Double(export.imageSize.width * export.imageSize.height) / 1e6
            return String(format: "%.0f megapixels · zoom %@", mp, v.zoomText)
        }
        return "\(Int(export.duration * Double(export.fps))) frames · home → \(v.zoomText)"
    }

    private var imageSettings: some View {
        Form {
            Picker("Size", selection: $export.imageSize) {
                ForEach(ExportController.imageSizes) { Text($0.label).tag($0) }
            }
            Picker("Smoothness", selection: $export.imageSamples) {
                Text("Draft (1×)").tag(1)
                Text("Good (4×)").tag(4)
                Text("Best (16×)").tag(16)
                Text("Extreme (64×)").tag(64)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 120)
        .disabled(export.running)
    }

    private var videoSettings: some View {
        Form {
            Picker("Resolution", selection: $export.videoSize) {
                ForEach(ExportController.videoSizes) { Text($0.label).tag($0) }
            }
            Picker("Frame rate", selection: $export.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            LabeledContent("Duration") {
                HStack {
                    Slider(value: $export.duration, in: 5...300, step: 1)
                    Text("\(Int(export.duration)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Smoothness", selection: $export.videoSamples) {
                Text("Fast (1×)").tag(1)
                Text("Good (2×)").tag(2)
                Text("Best (4×)").tag(4)
                Text("Extreme (9×)").tag(9)
            }
            Picker("Codec", selection: $export.codec) {
                ForEach(Exporter.Codec.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("Spin") {
                HStack {
                    Slider(value: $export.spin, in: 0...720, step: 15)
                    Text("\(Int(export.spin))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Animate colours", isOn: $export.cycleColors)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 330)
        .disabled(export.running)
    }

    private var progressView: some View {
        HStack(spacing: 14) {
            if let p = export.preview {
                Image(nsImage: p).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(export.status).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(export.eta).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                }
                if export.running {
                    ProgressView(value: export.progress)
                    Button("Cancel") { export.cancel() }.controlSize(.small)
                } else if let url = export.lastOutput {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Cancellation flag shared with a background export.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
