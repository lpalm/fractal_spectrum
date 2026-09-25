import Foundation
import Metal

/// A stream of compute command buffers for offline rendering. The GPU switches between queues only at
/// command-buffer boundaries, so iteration is split into chunks sized by measured cost: about 4 ms while
/// the interactive view is moving (keeping its frame rate), about 30 ms otherwise (keeping throughput).
final class PacedEncoder {
    private let queue: MTLCommandQueue
    private var commandBuffer: MTLCommandBuffer
    /// Encoder of the open command buffer.
    private(set) var encoder: MTLComputeCommandEncoder
    private var encodedSamples = 0
    private var inFlight: [MTLCommandBuffer] = []
    /// GPU time of all command buffers waited for so far.
    private(set) var gpuMs = 0.0
    private let lock = NSLock()
    /// Measured by completed chunks.
    private var msPerSample = 2e-5

    init(queue: MTLCommandQueue) {
        self.queue = queue
        commandBuffer = queue.makeCommandBuffer()!
        encoder = commandBuffer.makeComputeCommandEncoder()!
    }

    deinit { encoder.endEncoding() }

    /// Iterates a region (as `sampleMask` says per sample, if given), committing a command buffer after
    /// every chunk except the last, which stays open in `encoder` for the caller's follow-up work.
    func iterate(_ engine: Engine, plan: Engine.Plan, into gBuffer: MTLBuffer, origin: SIMD2<Int>, size: SIMD2<Int>,
                 bufferOrigin: SIMD2<UInt32>, bufferStride: UInt32, sampleMask: MTLBuffer? = nil) {
        var y = 0
        while y < size.y {
            // 8-row bands keep the 8×8 threadgroups full; a band over budget is split along the row.
            let rows = min(size.y - y, max(8, chunkSamples / size.x & ~7))
            var x = 0
            while x < size.x {
                let columns = min(size.x - x, max(64, chunkSamples / rows & ~7))
                if encodedSamples > 0 { flush() }
                engine.encodeIterate(encoder, plan: plan, into: gBuffer,
                                     origin: SIMD2(UInt32(origin.x + x), UInt32(origin.y + y)),
                                     size: SIMD2(UInt32(columns), UInt32(rows)),
                                     bufferOrigin: bufferOrigin, bufferStride: bufferStride, sampleMask: sampleMask)
                encodedSamples += columns * rows
                x += columns
            }
            y += rows
        }
    }

    /// Commits the open command buffer and opens the next.
    func flush() {
        encoder.endEncoding()
        let samples = encodedSamples
        commandBuffer.addCompletedHandler { [weak self] finished in
            guard let self, samples > 0 else { return }
            let ms = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            lock.withLock { self.msPerSample = max(ms, 0.05) / Double(samples) }
        }
        commandBuffer.commit()
        inFlight.append(commandBuffer)
        if inFlight.count > 2 { wait(for: inFlight.removeFirst()) }
        commandBuffer = queue.makeCommandBuffer()!
        encoder = commandBuffer.makeComputeCommandEncoder()!
        encodedSamples = 0
    }

    /// Commits the open command buffer and waits for all submitted work.
    func sync() {
        flush()
        for submitted in inFlight { wait(for: submitted) }
        inFlight.removeAll()
    }

    private func wait(for submitted: MTLCommandBuffer) {
        submitted.waitUntilCompleted()
        gpuMs += (submitted.gpuEndTime - submitted.gpuStartTime) * 1000
    }

    /// Samples for the next chunk; the floors keep chunks large enough to fill the GPU.
    private var chunkSamples: Int {
        let perSample = lock.withLock { msPerSample }
        return GPU.shared.isInteractive ? max(16384, Int(4 / perSample)) : max(262_144, Int(30 / perSample))
    }
}
