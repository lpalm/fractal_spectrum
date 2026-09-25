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

    /// A still-image export: scene, colours, size and anti-aliasing samples.
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

    /// Video codecs offered for zoom videos.
    public enum Codec: String, CaseIterable, Sendable, Identifiable {
        case hevc = "HEVC"
        case prores = "ProRes 422 HQ"
        public var id: String { rawValue }
    }

    /// A zoom video from `start` to `target`: look, size, timing and encoding.
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

        /// Encoder settings apart from the frame size.
        var encoderSettings: [String: Any] {
            switch codec {
            case .hevc:
                let bitsPerPixel = 0.35
                return [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: Int(Double(width * height * fps) * bitsPerPixel),
                        AVVideoExpectedSourceFrameRateKey: fps,
                        AVVideoMaxKeyFrameIntervalKey: fps,
                    ] as [String: Any],
                ]
            case .prores:
                return [AVVideoCodecKey: AVVideoCodecType.proRes422HQ]
            }
        }

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
            var view = target
            view.log2Radius = start.log2Radius + (target.log2Radius - start.log2Radius) * u
            let k = pow(exp2(view.log2Radius - start.log2Radius), 1.6)
            view.center = target.center.offset(by: start.center.minus(target.center) * k, precision: target.center.precision)
            view.rotation = start.rotation + (target.rotation - start.rotation) * u + spin * .pi / 180 * clamped
            return view
        }
    }

    /// Renders a zoom video. `progress(fraction, previewImage)` returns false to cancel; it is called
    /// after every frame, with a preview image at most four times a second.
    public func exportVideo(_ job: VideoJob, to url: URL,
                            progress: @escaping (Double, CGImage?) -> Bool) throws {
        let movie = try VideoWriter(url: url, fileType: job.codec == .prores ? .mov : .mp4, width: job.width,
                                    height: job.height, settings: job.encoderSettings, realTime: false)
        var saved = false
        defer { if !saved { movie.cancel() } }   // an export stopped by an error or the user leaves no file
        movie.startSession(at: .zero)
        let frames = job.frameCount
        var iteration = IterationSettings()
        iteration.maxIter = IterationTuner.lowestLimit
        let renderer = FrameRenderer(engine: engine, width: job.width, height: job.height)
        engine.colorOrigin = nil
        // One reference at the target serves every frame (they all contain it).
        _ = engine.references.reference(formula: job.formula, view: job.target, minSide: Double(min(job.width, job.height)),
                                        length: 1024, blocking: true)
        var previousView: Viewport?
        var previewDate = Date.distantPast
        for frame in 0..<frames {
            let t = frames > 1 ? Double(frame) / Double(frames - 1) : 1
            let view = job.view(at: t)
            var color = job.color
            color.offset = (color.offset + job.colorCycle * Double(frame) / Double(job.fps)).truncatingRemainder(dividingBy: 1)
            guard let (pixelBuffer, cvTexture) = movie.makeFrame(), let texture = CVMetalTextureGetTexture(cvTexture)
            else { throw movie.failure }
            // as in a live flight, colours settle faster towards the end, so the video arrives at the
            // colours its last view has on screen
            let zoomed = previousView.map { (view.log2Radius - $0.log2Radius) * (t > 0.8 ? 4 : 1) }
            let scene = FractalScene(formula: job.formula, view: view, iteration: iteration)
            // the Core Video texture must outlive the GPU's drawing into it
            let (stats, gpuMs) = withExtendedLifetime(cvTexture) {
                renderer.render(scene: scene, color: color, samples: job.samples, into: texture, zoomed: zoomed)
            }
            previousView = view
            // iterations only ever grow during a zoom-in, so colours never jump back
            let proposal = IterationTuner.adjustOffline(maxIter: iteration.maxIter, stats: stats, samples: job.width * job.height,
                                                        gpuMs: gpuMs, passes: job.samples)
            iteration.maxIter = max(iteration.maxIter, proposal)
            try movie.appendWhenReady(pixelBuffer, at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(job.fps)))
            // previews at most four times a second, and for every frame of a slow stretch
            let preview = Date().timeIntervalSince(previewDate) >= 0.25 ? Exporter.image(from: pixelBuffer) : nil
            if preview != nil { previewDate = Date() }
            if !progress(Double(frame + 1) / Double(frames), preview) { throw CocoaError(.userCancelled) }
        }
        try movie.finishAndWait()
        saved = true
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
