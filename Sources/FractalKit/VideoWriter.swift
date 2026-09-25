import Foundation
import AVFoundation
import CoreVideo
import Metal

/// A movie file written frame by frame from BGRA pixel buffers that Metal renders into; used by zoom
/// video exports and live recordings.
public final class VideoWriter: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let textureCache: CVMetalTextureCache

    /// Starts a movie at `url` (replacing any file there). `settings` are the encoder's output settings
    /// apart from the frame size; `realTime` suits live capture.
    public init(url: URL, fileType: AVFileType, width: Int, height: Int, settings: [String: Any], realTime: Bool) throws {
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var outputSettings = settings
        outputSettings[AVVideoWidthKey] = width
        outputSettings[AVVideoHeightKey] = height
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = realTime
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
    }

    public var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    /// Why writing failed, as an error to throw.
    public var failure: Error { writer.error ?? CocoaError(.fileWriteUnknown) }

    /// A pixel buffer for the next frame and a Metal texture of it; keep both until the GPU has drawn
    /// the frame. Nil when no buffer is available.
    public func makeFrame() -> (buffer: CVPixelBuffer, texture: CVMetalTexture)? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        var texture: CVMetalTexture?
        guard let pixelBuffer,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0,
                                                        &texture) == kCVReturnSuccess,
              let texture else { return nil }
        return (pixelBuffer, texture)
    }

    /// The movie's timeline starts at the first frame's time.
    public func startSession(at time: CMTime) { writer.startSession(atSourceTime: time) }

    @discardableResult
    public func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        adaptor.append(buffer, withPresentationTime: time)
    }

    /// Appends a frame once the encoder can take it (offline writing); throws when writing has failed,
    /// which would otherwise leave the encoder never ready.
    public func appendWhenReady(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw failure }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw failure }
    }

    /// Abandons the movie and deletes its file (a finished movie is kept).
    public func cancel() {
        switch writer.status {
        case .writing: writer.cancelWriting()   // which deletes the file
        case .failed: try? FileManager.default.removeItem(at: writer.outputURL)
        default: break
        }
    }

    /// Ends the movie, at `end` if given (the last frame holds until then), and reports whether it was
    /// written; a movie that could not be written is deleted.
    public func finish(at end: CMTime? = nil, completion: @escaping @Sendable (Bool) -> Void) {
        guard writer.status == .writing else {
            cancel()
            return completion(false)
        }
        input.markAsFinished()
        if let end { writer.endSession(atSourceTime: end) }
        writer.finishWriting { [self] in
            let written = writer.status == .completed
            if !written { cancel() }
            completion(written)
        }
    }

    /// Ends the movie and waits until it is written.
    public func finishAndWait() throws {
        let done = DispatchSemaphore(value: 0)
        finish { _ in done.signal() }
        done.wait()
        if writer.status != .completed { throw failure }
    }
}
