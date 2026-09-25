import Foundation
import Metal

/// A stream of compute command buffers for offline rendering. The GPU switches between queues only at
/// command-buffer boundaries, so iteration is split into chunks sized by measured cost: about 4 ms while
/// the interactive view is moving (keeping its frame rate), about 30 ms otherwise (keeping throughput).
final class PacedEncoder {
    private let queue: MTLCommandQueue
    private var cb: MTLCommandBuffer
    /// Encoder for the current command buffer.
    private(set) var enc: MTLComputeCommandEncoder
    private var encodedSamples = 0
    private var inFlight: [MTLCommandBuffer] = []
    /// GPU time of all command buffers waited for so far.
    private(set) var gpuMs = 0.0
    private let lock = NSLock()
    private var msPerSample = 2e-5

    init(queue: MTLCommandQueue) {
        self.queue = queue
        cb = queue.makeCommandBuffer()!
        enc = cb.makeComputeCommandEncoder()!
    }

    /// Iterates a region, committing a command buffer after every chunk except the last, which stays
    /// open in `enc` for the caller's follow-up work.
    func iterate(_ engine: Engine, plan: Engine.Plan, gbuf: MTLBuffer, origin: SIMD2<Int>, size: SIMD2<Int>,
                 bufOrigin: SIMD2<UInt32>, bufStride: UInt32) {
        var y = 0
        while y < size.y {
            // 8-row bands keep the 8×8 threadgroups full; a band over budget is split along the row.
            let rows = min(size.y - y, max(8, budget / size.x & ~7))
            var x = 0
            while x < size.x {
                let cols = min(size.x - x, max(64, budget / rows & ~7))
                if encodedSamples > 0 { flush() }
                engine.encodeIterate(enc, plan: plan, gbuf: gbuf,
                                     origin: SIMD2(UInt32(origin.x + x), UInt32(origin.y + y)),
                                     size: SIMD2(UInt32(cols), UInt32(rows)), bufOrigin: bufOrigin, bufStride: bufStride)
                encodedSamples += cols * rows
                x += cols
            }
            y += rows
        }
    }

    /// Commits the current command buffer and opens the next.
    func flush() {
        enc.endEncoding()
        let samples = encodedSamples
        cb.addCompletedHandler { [weak self] cb in
            guard let self, samples > 0 else { return }
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            lock.withLock { self.msPerSample = max(ms, 0.05) / Double(samples) }
        }
        cb.commit()
        inFlight.append(cb)
        if inFlight.count > 2 { wait(for: inFlight.removeFirst()) }
        cb = queue.makeCommandBuffer()!
        enc = cb.makeComputeCommandEncoder()!
        encodedSamples = 0
    }

    /// Commits the current command buffer and waits for all submitted work.
    func sync() {
        flush()
        for b in inFlight { wait(for: b) }
        inFlight.removeAll()
    }

    private func wait(for b: MTLCommandBuffer) {
        b.waitUntilCompleted()
        gpuMs += (b.gpuEndTime - b.gpuStartTime) * 1000
    }

    deinit { enc.endEncoding() }

    /// Samples for the next chunk; the floors keep chunks large enough to fill the GPU.
    private var budget: Int {
        let perSample = lock.withLock { msPerSample }
        return GPU.shared.isInteractive ? max(16384, Int(4 / perSample)) : max(262_144, Int(30 / perSample))
    }
}
