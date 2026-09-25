import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import FractalKit

/// Records the presented view to an HEVC movie in real time: each presented frame is drawn a second
/// time into a pixel buffer and appended with its presentation time (a still view simply holds).
final class LiveRecorder: @unchecked Sendable {
    let url: URL
    /// Frame size in pixels (the drawable's, rounded down to even for the encoder).
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let textureCache: CVMetalTextureCache
    /// Serialises the writer, which is not thread-safe.
    private let queue = DispatchQueue(label: "recording")
    private let start = CACurrentMediaTime()
    private var last = CMTime.negativeInfinity

    init(url: URL, drawable: SIMD2<Int>) throws {
        self.url = url
        width = drawable.x & ~1
        height = drawable.y & ~1
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(width * height * 60) * 0.3)],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, GPU.shared.device, nil, &cache)
        guard let cache, writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        textureCache = cache
        writer.startSession(atSourceTime: .zero)
    }

    /// A pixel buffer to draw the next frame into, with its texture; nil while the encoder is busy.
    func nextFrame() -> (buffer: CVPixelBuffer, texture: CVMetalTexture)? {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        var tex: CVMetalTexture?
        guard let pb, CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, width, height, 0, &tex)
                == kCVReturnSuccess, let tex else { return nil }
        return (pb, tex)
    }

    /// Appends a frame whose GPU work has completed, presented at `time` (CACurrentMediaTime).
    func append(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        queue.async { [self] in
            let t = CMTime(seconds: time - start, preferredTimescale: 6000)
            guard t > last, input.isReadyForMoreMediaData else { return }
            if adaptor.append(buffer, withPresentationTime: t) { last = t }
        }
    }

    /// Ends the movie at the current time (holding the last frame) and reports whether it was written;
    /// a movie without frames is removed.
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        let end = CMTime(seconds: CACurrentMediaTime() - start, preferredTimescale: 6000)
        queue.async { [self] in
            input.markAsFinished()
            writer.endSession(atSourceTime: max(end, last))
            writer.finishWriting { [writer, url] in
                let ok = writer.status == .completed
                if !ok { try? FileManager.default.removeItem(at: url) }
                completion(ok)
            }
        }
    }
}
