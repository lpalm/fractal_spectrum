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
    private let gpu = GPU.shared

    public init() {}

    public struct ImageJob: @unchecked Sendable {
        public var scene: FractalScene
        public var color: ColorSettings
        public var width: Int
        public var height: Int
        public var samples: Int
        /// Colour normalisation of the live view (keeps colours identical to the screen).
        public var colorStats: SIMD4<Float>?

        public init(scene: FractalScene, color: ColorSettings, width: Int, height: Int, samples: Int,
                    colorStats: SIMD4<Float>? = nil) {
            self.scene = scene
            self.color = color
            self.width = width
            self.height = height
            self.samples = samples
            self.colorStats = colorStats
        }
    }

    /// Renders and writes a PNG. `progress` returns false to cancel.
    public func exportImage(_ job: ImageJob, to url: URL, progress: @escaping (Double) -> Bool) throws {
        guard let image = engine.renderStill(scene: job.scene, color: job.color,
                                             options: .init(width: job.width, height: job.height, samples: job.samples,
                                                            tile: 2048, colorStats: job.colorStats),
                                             progress: progress) else {
            throw CocoaError(.userCancelled)
        }
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
        public var colorStats: SIMD4<Float>?
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

        public init(formula: Formula, target: Viewport, start: Viewport, color: ColorSettings, colorStats: SIMD4<Float>?,
                    width: Int, height: Int, fps: Int, duration: Double, samples: Int, codec: Codec,
                    spin: Double = 0, colorCycle: Double = 0) {
            self.formula = formula
            self.target = target
            self.start = start
            self.color = color
            self.colorStats = colorStats
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

        /// Zoom path: log radius moves at constant speed with eased ends; the target glides to the
        /// centre faster than the view shrinks, so it ends dead centre.
        public func view(at t: Double) -> Viewport {
            let e = 0.08
            let tt = min(max(t, 0), 1)
            // trapezoidal speed profile, integrated and normalised
            func pos(_ x: Double) -> Double {
                if x < e { return x * x / (2 * e) }
                if x > 1 - e { let y = 1 - x; return 1 - e - y * y / (2 * e) }
                return x - e / 2
            }
            let u = pos(tt) / pos(1)
            var v = target
            v.log2Radius = start.log2Radius + (target.log2Radius - start.log2Radius) * u
            let k = pow(exp2(v.log2Radius - start.log2Radius), 1.6)
            let off = start.center.minus(target.center) * k
            v.center = target.center.offset(by: off, precision: target.center.precision)
            v.rotation = start.rotation + (target.rotation - start.rotation) * u + spin * .pi / 180 * tt
            return v
        }
    }

    /// Renders a zoom video. `progress(fraction, previewImage)` returns false to cancel.
    public func exportVideo(_ job: VideoJob, to url: URL,
                            progress: @escaping (Double, CGImage?) -> Bool) throws {
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = job.codec == .prores ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var settings: [String: Any] = [
            AVVideoWidthKey: job.width,
            AVVideoHeightKey: job.height,
        ]
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
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
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
        CVMetalTextureCacheCreate(nil, nil, gpu.device, nil, &cache)
        guard let cache else { throw CocoaError(.fileWriteUnknown) }

        let frames = job.frameCount
        var iter = IterationSettings()
        iter.maxIter = 1000
        let renderer = FrameRenderer(engine: engine, width: job.width, height: job.height)
        if let cs = job.colorStats { engine.setColorStats(cs) } else { engine.resetSmoothing() }
        // One reference at the target serves every frame (they all contain it).
        _ = engine.references.reference(formula: job.formula, view: job.target, minSide: Double(min(job.width, job.height)),
                                        length: 1024, blocking: true)
        for f in 0..<frames {
            let t = frames > 1 ? Double(f) / Double(frames - 1) : 1
            let scene = FractalScene(formula: job.formula, view: job.view(at: t), iter: iter)
            var color = job.color
            color.offset = (color.offset + job.colorCycle * Double(f) / Double(job.fps)).truncatingRemainder(dividingBy: 1)
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pixelBuffer = pb else { throw CocoaError(.fileWriteUnknown) }
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, job.width, job.height, 0, &cvTex)
            guard let cvTex, let texture = CVMetalTextureGetTexture(cvTex) else { throw CocoaError(.fileWriteUnknown) }

            let started = ProcessInfo.processInfo.systemUptime
            let stats = renderer.render(scene: scene, color: color, samples: job.samples, into: texture,
                                        statsAlpha: f == 0 ? 1 : 0.35)
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            // iterations only ever grow during a zoom-in, so colours never jump back
            let pixels = job.width * job.height
            let next = IterationTuner.adjust(maxIter: iter.maxIter, stats: stats, samples: pixels)
            if next > iter.maxIter, IterationTuner.grownCost(ms, stats: stats, samples: pixels, maxIter: iter.maxIter, next: next)
                * 1000 / Double(pixels * max(job.samples, 1)) <= IterationTuner.offlineMicrosPerSample {
                iter.maxIter = next
            }

            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(job.fps)))
            let preview = f % 10 == 0 ? Exporter.image(from: pixelBuffer) : nil
            if !progress(Double(f + 1) / Double(frames), preview) {
                input.markAsFinished()
                writer.cancelWriting()
                throw CocoaError(.userCancelled)
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func image(from pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        return ctx.makeImage()
    }
}

/// Renders complete frames (all samples, all tiles) into a texture, keeping colour statistics
/// smoothed across frames.
final class FrameRenderer {
    let engine: Engine
    let width: Int
    let height: Int
    private let g: MTLBuffer
    private let acc: MTLTexture
    private let paced: PacedEncoder

    init(engine: Engine, width: Int, height: Int) {
        self.engine = engine
        self.width = width
        self.height = height
        g = engine.makeGBuffer(samples: width * height)
        acc = engine.makeAccumulator(width: width, height: height)
        paced = PacedEncoder(queue: engine.queue)
    }

    /// Returns the escape statistics of the first sample.
    func render(scene: FractalScene, color: ColorSettings, samples: Int, into dst: MTLTexture,
                statsAlpha: Float) -> FSStats {
        let size = SIMD2(UInt32(width), UInt32(height))
        var firstSlot: UInt32 = 0
        for s in 0..<max(samples, 1) {
            let slot = engine.nextStatsSlot()
            if s == 0 { firstSlot = slot }
            guard let plan = engine.makePlan(scene: scene, grid: .init(width: width, height: height, jitter: Engine.jitter(s)),
                                             enc: paced.enc, blocking: true, statsSlot: slot) else { break }
            engine.encodeStatsReset(paced.enc, slot: slot)
            paced.iterate(engine, plan: plan, gbuf: g, origin: .zero, size: SIMD2(width, height),
                          bufOrigin: .zero, bufStride: UInt32(width))
            if s == 0 { engine.encodeStatsSmooth(paced.enc, slot: slot, alpha: statsAlpha) }
            engine.encodeColorize(paced.enc, acc: acc, primary: .init(buffer: g, size: size), fallback: nil, color: color,
                                  accumulate: s > 0, outSize: size)
            if s == samples - 1 || samples <= 1 {
                engine.encodePresent(paced.enc, acc: acc, dst: dst, srcSize: size, background: color.interior, size: size)
            }
        }
        paced.sync()
        return engine.readStats(firstSlot)
    }
}
