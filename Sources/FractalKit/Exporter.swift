import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreGraphics
import CFractal

/// Offline rendering of high-resolution images and zoom videos. Uses its own engine so its
/// reference orbits never disturb the interactive view.
public final class Exporter: @unchecked Sendable {
    public let engine = Engine()

    public init() {}

    public struct ImageJob: @unchecked Sendable {
        public var scene: FractalScene
        public var color: ColorSettings
        public var width: Int
        public var height: Int
        public var samples: Int
        /// The live view's colour origin, so the image keeps the colours on screen.
        public var colorOrigin: Float?

        public init(scene: FractalScene, color: ColorSettings, width: Int, height: Int, samples: Int,
                    colorOrigin: Float? = nil) {
            self.scene = scene
            self.color = color
            self.width = width
            self.height = height
            self.samples = samples
            self.colorOrigin = colorOrigin
        }
    }

    /// Renders and writes a PNG. `progress` returns false to cancel.
    public func exportImage(_ job: ImageJob, to url: URL, progress: @escaping (Double) -> Bool) throws {
        let options = Engine.StillOptions(width: job.width, height: job.height, samples: job.samples,
                                          colorOrigin: job.colorOrigin)
        guard let image = engine.renderStill(scene: job.scene, color: job.color, options: options, progress: progress)
        else { throw CocoaError(.userCancelled) }
        try Engine.writePNG(image, to: url)
    }

    public enum Codec: String, CaseIterable, Sendable, Identifiable {
        case hevc = "HEVC"
        case prores = "ProRes 422 HQ"
        public var id: String { rawValue }
    }

    public struct VideoJob: @unchecked Sendable {
        public var formula: Formula
        public var target: Viewport
        /// View the video starts from (usually the overview).
        public var start: Viewport
        public var color: ColorSettings
        public var width: Int
        public var height: Int
        public var fps: Int
        public var duration: Double
        public var samples: Int
        public var codec: Codec
        /// Extra rotation over the whole video, in degrees.
        public var spin: Double
        /// Palette phase advance per second.
        public var colorCycle: Double

        public init(formula: Formula, target: Viewport, start: Viewport, color: ColorSettings,
                    width: Int, height: Int, fps: Int, duration: Double, samples: Int, codec: Codec,
                    spin: Double = 0, colorCycle: Double = 0) {
            self.formula = formula
            self.target = target
            self.start = start
            self.color = color
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.samples = samples
            self.codec = codec
            self.spin = spin
            self.colorCycle = colorCycle
        }

        public var frameCount: Int { max(1, Int((duration * Double(fps)).rounded())) }

        /// Share of the video spent speeding up at the start, and again slowing down at the end.
        public static let easing = 0.08

        /// Zoom speed between the eased ends, in doublings of magnification per second, of a video
        /// zooming in `doublings` times over `duration` seconds.
        public static func cruiseSpeed(doublings: Double, duration: Double) -> Double {
            doublings / (duration * (1 - easing))
        }

        /// Zoom path: log radius moves at constant speed with eased ends; the target glides to the
        /// centre faster than the view shrinks, so it ends dead centre.
        public func view(at t: Double) -> Viewport {
            let easing = VideoJob.easing
            // trapezoidal speed profile, integrated
            func position(_ x: Double) -> Double {
                if x < easing { return x * x / (2 * easing) }
                if x > 1 - easing { let y = 1 - x; return 1 - easing - y * y / (2 * easing) }
                return x - easing / 2
            }
            let clamped = min(max(t, 0), 1)
            let u = position(clamped) / position(1)
            var v = target
            v.log2Radius = start.log2Radius + (target.log2Radius - start.log2Radius) * u
            let k = pow(exp2(v.log2Radius - start.log2Radius), 1.6)
            v.center = target.center.offset(by: start.center.minus(target.center) * k, precision: target.center.precision)
            v.rotation = start.rotation + (target.rotation - start.rotation) * u + spin * .pi / 180 * clamped
            return v
        }
    }

    /// Renders a zoom video. `progress(fraction, previewImage)` returns false to cancel.
    public func exportVideo(_ job: VideoJob, to url: URL,
                            progress: @escaping (Double, CGImage?) -> Bool) throws {
        let movie = try MovieWriter(url: url, job: job)
        let frames = job.frameCount
        var iter = IterationSettings()
        iter.maxIter = 1000
        let renderer = FrameRenderer(engine: engine, width: job.width, height: job.height)
        engine.colorOrigin = nil
        // One reference at the target serves every frame (they all contain it).
        _ = engine.references.reference(formula: job.formula, view: job.target, minSide: Double(min(job.width, job.height)),
                                        length: 1024, blocking: true)
        var previousView: Viewport?
        for frame in 0..<frames {
            let t = frames > 1 ? Double(frame) / Double(frames - 1) : 1
            let view = job.view(at: t)
            var color = job.color
            color.offset = (color.offset + job.colorCycle * Double(frame) / Double(job.fps)).truncatingRemainder(dividingBy: 1)
            let (pixelBuffer, texture) = try movie.nextFrame()
            // as in a live flight, colours settle faster towards the end, so the video arrives at the
            // colours its last view has on screen
            let zoomed = previousView.map { (view.log2Radius - $0.log2Radius) * (t > 0.8 ? 4 : 1) }
            let (stats, gpuMs) = renderer.render(scene: FractalScene(formula: job.formula, view: view, iter: iter),
                                                 color: color, samples: job.samples, into: texture, zoomed: zoomed)
            previousView = view
            // iterations only ever grow during a zoom-in, so colours never jump back
            let proposal = IterationTuner.adjustOffline(maxIter: iter.maxIter, stats: stats, samples: job.width * job.height,
                                                        gpuMs: gpuMs, passes: job.samples)
            iter.maxIter = max(iter.maxIter, proposal)
            movie.append(pixelBuffer, frame: frame)
            let preview = frame % 10 == 0 ? Exporter.image(from: pixelBuffer) : nil
            if !progress(Double(frame + 1) / Double(frames), preview) {
                movie.cancel()
                throw CocoaError(.userCancelled)
            }
        }
        try movie.finish()
    }

    /// The pixels of a BGRA pixel buffer as an image (for previews).
    static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: CVPixelBufferGetWidth(pixelBuffer),
                                      height: CVPixelBufferGetHeight(pixelBuffer), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return context.makeImage()
    }
}

/// Writes the frames of a zoom video, handing out Metal-backed pixel buffers to render into.
private final class MovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let textureCache: CVMetalTextureCache
    private let job: Exporter.VideoJob

    init(url: URL, job: Exporter.VideoJob) throws {
        self.job = job
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: job.codec == .prores ? .mov : .mp4)
        var settings: [String: Any] = [AVVideoWidthKey: job.width, AVVideoHeightKey: job.height]
        switch job.codec {
        case .hevc:
            let bitsPerPixel = 0.35
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(Double(job.width * job.height * job.fps) * bitsPerPixel),
                AVVideoExpectedSourceFrameRateKey: job.fps,
                AVVideoMaxKeyFrameIntervalKey: job.fps,
            ] as [String: Any]
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: job.width,
            kCVPixelBufferHeightKey as String: job.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, GPU.shared.device, nil, &cache)
        guard let cache else { throw CocoaError(.fileWriteUnknown) }
        textureCache = cache
    }

    /// A pixel buffer for the next frame and a texture of it to render into.
    func nextFrame() throws -> (CVPixelBuffer, MTLTexture) {
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, job.width, job.height,
                                                  0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { throw CocoaError(.fileWriteUnknown) }
        return (pixelBuffer, texture)
    }

    /// Appends a rendered frame, waiting for the encoder to take it.
    func append(_ pixelBuffer: CVPixelBuffer, frame: Int) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(job.fps)))
    }

    func cancel() {
        input.markAsFinished()
        writer.cancelWriting()
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// Renders complete frames (all samples) into a texture, moving the colour origin with the zoom
/// from frame to frame.
public final class FrameRenderer {
    let engine: Engine
    public let width: Int
    public let height: Int
    private let gBuffer: MTLBuffer
    private let accumulator: MTLTexture
    private let paced: PacedEncoder

    public init(engine: Engine, width: Int, height: Int) {
        self.engine = engine
        self.width = width
        self.height = height
        gBuffer = engine.makeGBuffer(samples: width * height)
        accumulator = engine.makeAccumulator(width: width, height: height)
        paced = PacedEncoder(queue: engine.queue)
    }

    /// Renders one frame; `zoomed` is the zoom since the previous frame in doublings (nil for a first
    /// frame). Returns the escape statistics of the first sample and the GPU time taken.
    @discardableResult
    public func render(scene: FractalScene, color: ColorSettings, samples: Int, into target: MTLTexture,
                       zoomed: Double?) -> (stats: FSStats, gpuMs: Double) {
        let startMs = paced.gpuMs
        let size = SIMD2(UInt32(width), UInt32(height))
        let region = Engine.GBufferRegion(buffer: gBuffer, size: size)
        var firstSlot: UInt32 = 0
        for sample in 0..<max(samples, 1) {
            let slot = engine.nextStatsSlot()
            if sample == 0 { firstSlot = slot }
            let grid = Engine.Grid(width: width, height: height, jitter: Engine.jitter(sample))
            guard let plan = engine.makePlan(scene: scene, grid: grid, encoder: paced.encoder, blocking: true,
                                             statsSlot: slot) else { break }
            engine.encodeStatsReset(paced.encoder, slot: slot)
            paced.iterate(engine, plan: plan, into: gBuffer, origin: .zero, size: SIMD2(width, height),
                          bufferOrigin: .zero, bufferStride: UInt32(width))
            if sample == 0 { engine.encodeColorOrigin(paced.encoder, slot: slot, zoomed: zoomed) }
            engine.encodeColorize(paced.encoder, into: accumulator, from: region, fallback: nil, color: color,
                                  accumulate: sample > 0, size: size)
            if sample == samples - 1 || samples <= 1 {
                engine.encodePresent(paced.encoder, from: accumulator, into: target, sourceSize: size,
                                     background: color.interior, size: size)
            }
        }
        paced.sync()
        return (engine.readStats(firstSlot), paced.gpuMs - startMs)
    }
}
