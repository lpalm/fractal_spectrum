import Foundation
import Metal
import CFractal

/// Owns the Metal device, compiled shader library and specialised pipelines.
public final class GPU: @unchecked Sendable {
    public static let shared = GPU()

    public let device: MTLDevice
    let library: MTLLibrary
    private var cache: [PipelineKey: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var interactiveUntil = 0.0

    /// Function-constant specialisation of an escape-time or BLA kernel.
    struct PipelineKey: Hashable {
        var name: String
        var formula: Int32 = 0
        var power: Int32 = 2
        var julia = false
        var useBLA = false
        var withDer = false
        var deep = false
        var interior = true
    }

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

    var isInteractive: Bool { lock.withLock { ProcessInfo.processInfo.systemUptime < interactiveUntil } }

    func pipeline(_ key: PipelineKey) -> MTLComputePipelineState {
        lock.lock()
        if let p = cache[key] {
            lock.unlock()
            return p
        }
        lock.unlock()
        let p = makePipeline(key)
        lock.lock()
        cache[key] = p
        lock.unlock()
        return p
    }

    func pipeline(_ name: String) -> MTLComputePipelineState {
        pipeline(PipelineKey(name: name))
    }

    private static let specialised: Set<String> = ["iterate_direct", "iterate_perturb", "bla_init", "bla_merge"]

    private func makePipeline(_ key: PipelineKey) -> MTLComputePipelineState {
        do {
            let function: MTLFunction
            if GPU.specialised.contains(key.name) {
                let values = MTLFunctionConstantValues()
                var formula = key.formula, power = key.power
                var julia = key.julia, bla = key.useBLA, der = key.withDer, deep = key.deep, interior = key.interior
                values.setConstantValue(&formula, type: .int, index: 0)
                values.setConstantValue(&power, type: .int, index: 1)
                values.setConstantValue(&julia, type: .bool, index: 2)
                values.setConstantValue(&bla, type: .bool, index: 3)
                values.setConstantValue(&der, type: .bool, index: 4)
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
            for der in [true, false] {
                _ = self.pipeline(PipelineKey(name: "iterate_direct", withDer: der))
                for deep in [false, true] {
                    _ = self.pipeline(PipelineKey(name: "iterate_perturb", useBLA: true, withDer: der, deep: deep))
                }
            }
            _ = self.pipeline(PipelineKey(name: "bla_init"))
            _ = self.pipeline(PipelineKey(name: "bla_merge"))
        }
    }

    func dispatch2D(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, width: Int, height: Int) {
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        enc.setComputePipelineState(pso)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: tg)
    }

    func dispatch1D(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, count: Int) {
        enc.setComputePipelineState(pso)
        let w = min(pso.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: max(count, 1), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }
}
