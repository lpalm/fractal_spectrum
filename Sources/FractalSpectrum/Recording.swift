import AVFoundation
import CoreVideo
import QuartzCore
import FractalKit

/// Records the presented view to an HEVC movie in real time: each presented frame is drawn a second
/// time into a pixel buffer and appended with its presentation time (a still view simply holds).
final class LiveRecorder: @unchecked Sendable {
    let url: URL
    private let movie: VideoWriter
    /// Frame size in pixels (the drawable's, rounded down to even for the encoder).
    var width: Int { movie.width }
    var height: Int { movie.height }
    /// Serialises the writer, which is not thread-safe.
    private let queue = DispatchQueue(label: "recording")
    private let startTime = CACurrentMediaTime()
    /// Presentation time of the last appended frame.
    private var lastTime = CMTime.negativeInfinity

    init(url: URL, drawableSize: SIMD2<Int>) throws {
        self.url = url
        let width = drawableSize.x & ~1, height = drawableSize.y & ~1
        movie = try VideoWriter(url: url, fileType: .mp4, width: width, height: height, settings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(width * height * 60) * 0.3)],
        ], realTime: true)
    }

    /// A pixel buffer to draw the next frame into, with its texture; nil while the encoder is busy.
    func nextFrame() -> (buffer: CVPixelBuffer, texture: CVMetalTexture)? {
        movie.isReadyForMoreMediaData ? movie.makeFrame() : nil
    }

    /// Appends a frame whose GPU work has completed, presented at `time` (CACurrentMediaTime).
    func append(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        queue.async { [self] in
            let t = CMTime(seconds: time - startTime, preferredTimescale: 6000)
            guard t > lastTime, movie.isReadyForMoreMediaData else { return }
            // the movie starts with its first frame (a session from 0 would open with black)
            if lastTime == .negativeInfinity { movie.startSession(at: t) }
            if movie.append(buffer, at: t) { lastTime = t }
        }
    }

    /// Ends the movie at the current time (holding the last frame) and reports whether it was written;
    /// a movie without frames is removed.
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        let end = CMTime(seconds: CACurrentMediaTime() - startTime, preferredTimescale: 6000)
        queue.async { [self] in
            // without frames there is no session to end, and nothing to keep
            guard lastTime != .negativeInfinity else {
                movie.cancel()
                return completion(false)
            }
            movie.finish(at: max(end, lastTime), completion: completion)
        }
    }
}
