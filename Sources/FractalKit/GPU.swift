import Foundation
import Metal
import CFractal

/// Owns the Metal device, the shader library (compiled from source at launch) and the pipelines
/// specialised from it.
public final class GPU: @unchecked Sendable {
    public static let shared = GPU()

    public let device: MTLDevice
    let library: MTLLibrary
    private var pipelines: [PipelineKey: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var interactiveUntil = 0.0

    /// A kernel and the function constants it is specialised for (escape-time and BLA kernels only).
    struct PipelineKey: Hashable {
        var name: String
        /// FS_FORMULA_*.
        var family: Int32 = 0
        var power: Int32 = 2
        var julia = false
        var useBLA = false
        var derivative = false
        var deep = false
        var interior = true
    }

    /// Kernels that take the function constants of `PipelineKey`.
    private static let specializedKernels: Set<String> = ["iterate_direct", "iterate_perturb", "bla_init", "bla_merge"]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available")
        }
        self.device = device
        let options = MTLCompileOptions()
        options.mathMode = .fast
        options.languageVersion = .version3_1
        do {
            library = try device.makeLibrary(source: fractalShaderSource, options: options)
        } catch {
            fatalError("Shader compilation failed: \(error)")
        }
    }

    /// Called while the interactive view is moving; offline renders then keep their command buffers short.
    public func noteInteraction() {
        lock.withLock { interactiveUntil = ProcessInfo.processInfo.systemUptime + 0.3 }
    }

    /// Whether the interactive view moved within the last 0.3 s.
    var isInteractive: Bool { lock.withLock { ProcessInfo.processInfo.systemUptime < interactiveUntil } }

    func pipeline(_ key: PipelineKey) -> MTLComputePipelineState {
        if let cached = lock.withLock({ pipelines[key] }) { return cached }
        // compiled outside the lock, so that cached pipelines stay available meanwhile
        let pipeline = makePipeline(key)
        lock.withLock { pipelines[key] = pipeline }
        return pipeline
    }

    func pipeline(_ name: String) -> MTLComputePipelineState {
        pipeline(PipelineKey(name: name))
    }

    private func makePipeline(_ key: PipelineKey) -> MTLComputePipelineState {
        do {
            let function: MTLFunction
            if GPU.specializedKernels.contains(key.name) {
                let values = MTLFunctionConstantValues()
                var family = key.family, power = key.power
                var julia = key.julia, useBLA = key.useBLA, derivative = key.derivative, deep = key.deep
                var interior = key.interior
                values.setConstantValue(&family, type: .int, index: 0)
                values.setConstantValue(&power, type: .int, index: 1)
                values.setConstantValue(&julia, type: .bool, index: 2)
                values.setConstantValue(&useBLA, type: .bool, index: 3)
                values.setConstantValue(&derivative, type: .bool, index: 4)
                values.setConstantValue(&deep, type: .bool, index: 5)
                values.setConstantValue(&interior, type: .bool, index: 6)
                function = try library.makeFunction(name: key.name, constantValues: values)
            } else {
                guard let f = library.makeFunction(name: key.name) else { fatalError("Missing kernel \(key.name)") }
                function = f
            }
            return try device.makeComputePipelineState(function: function)
        } catch {
            fatalError("Pipeline \(key) failed: \(error)")
        }
    }

    /// Compiles the pipelines an interactive session needs first, off the main thread.
    public func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            for name in ["colorize", "present", "stats_reset", "color_origin"] { _ = self.pipeline(name) }
            for derivative in [true, false] {
                _ = self.pipeline(PipelineKey(name: "iterate_direct", derivative: derivative))
                for deep in [false, true] {
                    _ = self.pipeline(PipelineKey(name: "iterate_perturb", useBLA: true, derivative: derivative, deep: deep))
                }
            }
            _ = self.pipeline(PipelineKey(name: "bla_init"))
            _ = self.pipeline(PipelineKey(name: "bla_merge"))
        }
    }

    /// Runs `pipeline` once per element of a width x height grid, in 8 x 8 threadgroups.
    func dispatch2D(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    /// Runs `pipeline` once per element of `count` (at least once).
    func dispatch1D(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, count: Int) {
        encoder.setComputePipelineState(pipeline)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: max(count, 1), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }
}
