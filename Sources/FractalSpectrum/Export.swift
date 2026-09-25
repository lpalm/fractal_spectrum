import AppKit
import SwiftUI
import Observation
import FractalKit

private let defaults = UserDefaults.standard

/// Image and video export settings, where exports are saved, and the progress of a running export.
@MainActor @Observable
final class ExportController {
    /// What the export sheet produces.
    enum Kind: String, CaseIterable, Identifiable {
        case image = "Image", video = "Video"
        var id: String { rawValue }
    }

    /// A named output size in pixels.
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

    static let fullHD = Size(name: "1080p", width: 1920, height: 1080)
    static let videoSizes: [Size] = [
        Size(name: "Preview", width: 320, height: 180),
        Size(name: "360p", width: 640, height: 360),
        Size(name: "720p", width: 1280, height: 720),
        fullHD,
        Size(name: "1440p", width: 2560, height: 1440),
        Size(name: "4K UHD", width: 3840, height: 2160),
        Size(name: "Vertical 1080×1920", width: 1080, height: 1920),
    ]

    /// Longest zoom video, in seconds.
    static let longestVideo = 1800.0

    var kind = Kind.image
    /// Suggested for each view when the sheet opens.
    var duration = 20.0

    // Settings remembered across launches
    var imageSize = ExportController.imageSizes.first { $0.name == defaults.string(forKey: "export.imageSize") }
        ?? ExportController.imageSizes[0] {
        didSet { defaults.set(imageSize.name, forKey: "export.imageSize") }
    }
    var imageSamples = defaults.object(forKey: "export.imageSamples") as? Int ?? 16 {
        didSet { defaults.set(imageSamples, forKey: "export.imageSamples") }
    }
    var videoSize = ExportController.videoSizes.first { $0.name == defaults.string(forKey: "export.videoSize") }
        ?? ExportController.fullHD {
        didSet { defaults.set(videoSize.name, forKey: "export.videoSize") }
    }
    var fps = defaults.object(forKey: "export.fps") as? Int ?? 60 {
        didSet { defaults.set(fps, forKey: "export.fps") }
    }
    var videoSamples = defaults.object(forKey: "export.videoSamples") as? Int ?? 4 {
        didSet { defaults.set(videoSamples, forKey: "export.videoSamples") }
    }
    var codec = Exporter.Codec(rawValue: defaults.string(forKey: "export.codec") ?? "") ?? .hevc {
        didSet { defaults.set(codec.rawValue, forKey: "export.codec") }
    }
    var spin = defaults.object(forKey: "export.spin") as? Double ?? 0 {
        didSet { defaults.set(spin, forKey: "export.spin") }
    }
    var cycleColors = defaults.bool(forKey: "export.cycleColors") {
        didSet { defaults.set(cycleColors, forKey: "export.cycleColors") }
    }
    /// Folders that exports are saved to.
    var imageFolder = ExportController.rememberedFolder("export.imageFolder", default: .picturesDirectory) {
        didSet { defaults.set(imageFolder.path, forKey: "export.imageFolder") }
    }
    var videoFolder = ExportController.rememberedFolder("export.videoFolder", default: .moviesDirectory) {
        didSet { defaults.set(videoFolder.path, forKey: "export.videoFolder") }
    }

    // Running export
    var running = false
    var progress = 0.0 {
        didSet {
            let now = Date()
            recentProgress.append((now, progress))
            // keep the last minute, from its oldest sample on
            while recentProgress.count > 2, now.timeIntervalSince(recentProgress[1].date) > 60 { recentProgress.removeFirst() }
        }
    }
    var preview: NSImage?
    var status = ""
    var lastOutput: URL?
    /// Called once when the running export ends.
    @ObservationIgnored var onFinish: (() -> Void)?
    /// Receives the outcome of every export ("Saved …", "Cancelled", or the error), for a notice.
    @ObservationIgnored var announce: ((String) -> Void)?
    @ObservationIgnored private let cancelToken = CancelToken()
    @ObservationIgnored private var startDate = Date()
    /// When the last export ended.
    @ObservationIgnored private var endDate: Date?
    /// Frames of the running (or last) export; 0 for an image.
    @ObservationIgnored private var frameCount = 0
    /// Progress over about the last minute: its pace gives the remaining time, which the pace since
    /// the start would underestimate where frames slow down.
    @ObservationIgnored private var recentProgress: [(date: Date, progress: Double)] = []

    func cancel() { cancelToken.cancelled = true }

    /// Remaining time of the running export at its pace over about the last minute.
    var remainingTimeText: String {
        guard running, let oldest = recentProgress.first, let newest = recentProgress.last,
              newest.progress > oldest.progress, newest.date.timeIntervalSince(oldest.date) > 3 else { return "" }
        let left = newest.date.timeIntervalSince(oldest.date) / (newest.progress - oldest.progress) * (1 - newest.progress)
        if left < 60 { return String(format: "%.0f s left", left) }
        if left < 3600 { return String(format: "%.0f min left", left / 60) }
        return String(format: "%.1f h left", left / 3600)
    }

    /// Time taken by the running (or last) export and, for a video, its frames per second so far:
    /// "12:05 · 3.7 fps".
    var paceText: String {
        guard let end = running ? Date() : endDate else { return "" }
        let seconds = end.timeIntervalSince(startDate)
        let whole = Int(seconds)
        let time = whole < 3600 ? String(format: "%d:%02d", whole / 60, whole % 60)
            : String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        guard frameCount > 0, seconds > 0 else { return time }
        return time + String(format: " · %.1f fps", progress * Double(frameCount) / seconds)
    }

    /// Suggested video length: about one doubling of zoom per 0.45 s, within 10 s and the longest video.
    static func suggestedDuration(for view: Viewport, from start: Viewport) -> Double {
        let doublings = max(start.log2Radius - view.log2Radius, 1)
        return min(longestVideo, max(10, (doublings * 0.45).rounded()))
    }

    /// The folder the current kind of export is saved to.
    var folder: URL { kind == .image ? imageFolder : videoFolder }

    /// Lets the user pick another folder for the current kind of export.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = kind == .image ? "Images are saved to this folder." : "Videos are saved to this folder."
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == .image { imageFolder = url } else { videoFolder = url }
    }

    /// The folder remembered under `key`, else the given standard folder. Whether it can still be
    /// saved to is checked when something is saved.
    private static func rememberedFolder(_ key: String, default directory: FileManager.SearchPathDirectory) -> URL {
        defaults.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }

    /// Why files can't be saved to `folder` ("“Exports” is missing"), or nil if they can.
    static func problem(savingTo folder: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "“\(folder.lastPathComponent)” is missing"
        }
        return FileManager.default.isWritableFile(atPath: folder.path) ? nil : "“\(folder.lastPathComponent)” is read-only"
    }

    /// A new file in `folder` named after the current time, like the system's screenshots
    /// ("Spectrum 2026-09-25 at 09.41.00.png"), numbered if that name is taken.
    static func newFile(_ prefix: String = "Spectrum", in folder: URL, extension fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(prefix) \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent("\(name).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(number).\(fileExtension)")
            number += 1
        }
        return url
    }

    /// An image of the current view at the chosen size and smoothness.
    func imageJob(model: AppModel) -> Exporter.ImageJob {
        var iteration = model.iteration
        iteration.maxIter = max(iteration.maxIter, IterationTuner.lowestLimit)
        return Exporter.ImageJob(scene: FractalScene(formula: model.formula, view: model.camera.view, iteration: iteration),
                                 color: model.color, width: imageSize.width, height: imageSize.height,
                                 samples: imageSamples, colorOrigin: model.engine.colorOrigin)
    }

    /// A zoom from the overview to the current view with the chosen video settings.
    func videoJob(model: AppModel) -> Exporter.VideoJob {
        Exporter.VideoJob(formula: model.formula, target: model.camera.view, start: Viewport.home(for: model.formula),
                          color: model.color, width: videoSize.width, height: videoSize.height, fps: fps,
                          duration: duration, samples: videoSamples, codec: codec, spin: spin,
                          colorCycle: cycleColors ? 0.05 : 0)
    }

    /// Renders an image into the image folder (or to `destination`).
    func render(_ job: Exporter.ImageJob, to destination: URL? = nil) {
        let url = destination ?? ExportController.newFile(in: imageFolder, extension: "png")
        run("Rendering \(job.width)×\(job.height)", to: url) { [weak self] exporter, token in
            try exporter.exportImage(job, to: url) { fraction in
                DispatchQueue.main.async { self?.progress = fraction }
                return !token.cancelled
            }
        }
    }

    /// Renders a zoom video into the video folder (or to `destination`).
    func render(_ job: Exporter.VideoJob, to destination: URL? = nil) {
        let url = destination ?? ExportController.newFile(in: videoFolder, extension: job.codec == .prores ? "mov" : "mp4")
        let frames = job.frameCount
        run("Frame 0 of \(frames.formatted())", frames: frames, to: url) { [weak self] exporter, token in
            try exporter.exportVideo(job, to: url) { fraction, image in
                DispatchQueue.main.async {
                    self?.progress = fraction
                    // the count keeps moving where frames are slow and the bar hardly does
                    self?.status = "Frame \(Int((fraction * Double(frames)).rounded()).formatted()) of \(frames.formatted())"
                    if let image { self?.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
                }
                return !token.cancelled
            }
        }
    }

    /// Runs an export off the main thread, one at a time; `render` checks the token to stop early.
    private func run(_ title: String, frames: Int = 0, to url: URL,
                     render: @escaping @Sendable (Exporter, CancelToken) throws -> Void) {
        guard !running else {
            announce?("An export is already running")
            return
        }
        begin(title, frames: frames)
        if let problem = ExportController.problem(savingTo: url.deletingLastPathComponent()) {
            return finish(url: nil, message: "Export failed: \(problem)")
        }
        let token = cancelToken
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try render(Exporter(), token)
                await self?.finish(url: url, message: "Saved \(url.lastPathComponent)")
            } catch {
                await self?.finish(url: nil, message: token.cancelled ? "Cancelled" : "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func begin(_ text: String, frames: Int) {
        cancelToken.cancelled = false
        startDate = Date()
        endDate = nil
        frameCount = frames
        recentProgress = []
        running = true
        progress = 0
        preview = nil
        status = text
    }

    private func finish(url: URL?, message: String) {
        endDate = Date()
        running = false
        status = message
        if let url { lastOutput = url }
        announce?(message)
        onFinish?()
        onFinish = nil
    }
}

/// Export sheet: image and zoom-video settings in sections, where the file goes, and live progress.
struct ExportSheet: View {
    @Bindable var model: AppModel
    @Bindable var export: ExportController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Export")
                    .font(.rounded(22, .bold))
                Spacer()
                Picker("", selection: $export.kind) {
                    ForEach(ExportController.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(export.running)
            }
            Form {
                if export.kind == .image { imageSections } else { videoSections }
                Section("Save to") {
                    LabeledContent {
                        Button("Change…") { export.chooseFolder() }
                    } label: {
                        Text((export.folder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(export.folder.path)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(export.running)
            if export.running || export.lastOutput != nil || !export.status.isEmpty { progressView }
            HStack {
                Text(summary)
                    .font(.rounded(12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(export.kind == .image ? "Save Image" : "Render Video") {
                    switch export.kind {
                    case .image: export.render(export.imageJob(model: model))
                    case .video: export.render(export.videoJob(model: model))
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(export.running)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            export.duration = ExportController.suggestedDuration(for: model.camera.view, from: Viewport.home(for: model.formula))
        }
    }

    @ViewBuilder private var imageSections: some View {
        Section("Image") {
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
    }

    @ViewBuilder private var videoSections: some View {
        Section("Format") {
            Picker("Resolution", selection: $export.videoSize) {
                ForEach(ExportController.videoSizes) { Text($0.label).tag($0) }
            }
            Picker("Frame rate", selection: $export.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Codec", selection: $export.codec) {
                ForEach(Exporter.Codec.allCases) { Text($0.rawValue).tag($0) }
            }
        }
        Section("Zoom") {
            LabeledContent("Duration") {
                HStack {
                    // logarithmic, so that short videos can be set to the second and long ones to the minute
                    Slider(value: Binding(get: { log(export.duration) }, set: { export.duration = exp($0).rounded() }),
                           in: log(5)...log(ExportController.longestVideo))
                    Text(durationText).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            LabeledContent("Speed", value: speedText)
            LabeledContent("Spin") {
                HStack {
                    Slider(value: $export.spin, in: 0...720, step: 15)
                    Text("\(Int(export.spin))°").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
        Section("Look") {
            Picker("Smoothness", selection: $export.videoSamples) {
                Text("Fast (1×)").tag(1)
                Text("Good (2×)").tag(2)
                Text("Best (4×)").tag(4)
                Text("Extreme (9×)").tag(9)
            }
            Toggle("Animate colours", isOn: $export.cycleColors)
        }
    }

    /// "45 s" or "12:30".
    private var durationText: String {
        let seconds = Int(export.duration)
        return seconds < 60 ? "\(seconds) s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// How much the video magnifies per second and per frame between its eased start and end.
    private var speedText: String {
        let doublings = Viewport.home(for: model.formula).log2Radius - model.camera.view.log2Radius
        guard doublings > 0 else { return "—" }
        let perSecond = Exporter.VideoJob.cruiseSpeed(doublings: doublings, duration: export.duration)
        return "\(factorText(doublings: perSecond)) per second · \(factorText(doublings: perSecond / Double(export.fps))) per frame"
    }

    /// A magnification of 2^doublings: "×1.026", "×4.6", "×2,048" or, beyond a million, "×1.5e54".
    private func factorText(doublings: Double) -> String {
        let factor = exp2(doublings)
        switch factor {
        case ..<2: return String(format: "×%.3f", factor)
        case ..<10: return String(format: "×%.1f", factor)
        case ..<1e6: return "×" + Int(factor.rounded()).formatted()
        default:
            let (mantissa, exponent) = scientific(log10: doublings * log10(2.0), digits: 1)
            return String(format: "×%.1fe%d", mantissa, exponent)
        }
    }

    private var summary: String {
        let view = model.camera.view
        if export.kind == .image {
            let megapixels = Double(export.imageSize.width * export.imageSize.height) / 1e6
            return String(format: "%.0f megapixels · zoom %@", megapixels, view.zoomText)
        }
        return "\(Int(export.duration * Double(export.fps)).formatted()) frames · home → \(view.zoomText)"
    }

    private var progressView: some View {
        HStack(spacing: 14) {
            if let preview = export.preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(export.status).font(.rounded(13, .semibold))
                    Spacer()
                    Text(export.remainingTimeText).font(.rounded(12)).foregroundStyle(.secondary).monospacedDigit()
                }
                if export.running { ProgressView(value: export.progress) }
                HStack {
                    if export.running {
                        Button("Cancel Export") { export.cancel() }.controlSize(.small)
                    } else if let url = export.lastOutput {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .controlSize(.small)
                    }
                    Spacer()
                    Text(export.paceText).font(.rounded(12)).foregroundStyle(.secondary).monospacedDigit()
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
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
