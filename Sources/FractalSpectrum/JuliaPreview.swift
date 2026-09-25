import MetalKit
import SwiftUI
import FractalKit

/// The Julia parameter under the pointer.
struct JuliaHover: Equatable {
    /// Pointer position in the canvas (points, origin top-left).
    var point: CGPoint
    var re: Double
    var im: Double
}

/// Floating preview of the Julia set for the parameter under the pointer, placed beside it.
struct JuliaInset: View {
    let hover: JuliaHover
    let formula: Formula
    let color: ColorSettings
    let canvas: CGSize

    var body: some View {
        let size = CGSize(width: 240, height: 160)
        let offset = size.width / 2 + 36
        let x = hover.point.x + offset + size.width / 2 < canvas.width ? hover.point.x + offset : hover.point.x - offset
        let y = min(max(hover.point.y, size.height / 2 + 30), canvas.height - size.height / 2 - 30)
        VStack(alignment: .leading, spacing: 6) {
            JuliaPreviewView(re: hover.re, im: hover.im, formula: formula, color: color)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(String(format: "c = %.5f %+.5fi", hover.re, hover.im))
                .font(.rounded(11, .medium))
                .monospacedDigit()
                .padding(.horizontal, 4)
        }
        .padding(8)
        .panelGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .position(x: x, y: y)
    }
}

/// Metal view drawing the Julia set of one parameter, redrawn when the parameter changes.
struct JuliaPreviewView: NSViewRepresentable {
    let re: Double
    let im: Double
    let formula: Formula
    let color: ColorSettings

    func makeCoordinator() -> JuliaPreviewRenderer { JuliaPreviewRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: GPU.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let julia = formula.juliaSet(re: re, im: im)
        context.coordinator.scene = FractalScene(formula: julia, view: Viewport.home(for: julia), iteration: IterationSettings())
        context.coordinator.color = color
        view.needsDisplay = true
    }
}

/// Renders the preview synchronously into the view's drawable (a small frame takes about a millisecond).
final class JuliaPreviewRenderer: NSObject, MTKViewDelegate {
    private let engine = Engine()
    private var frameRenderer: FrameRenderer?
    var scene: FractalScene?
    var color = ColorSettings()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        guard let scene, width > 0, height > 0, let drawable = view.currentDrawable else { return }
        if frameRenderer?.width != width || frameRenderer?.height != height {
            frameRenderer = FrameRenderer(engine: engine, width: width, height: height)
        }
        frameRenderer?.render(scene: scene, color: color, samples: 2, into: drawable.texture, zoomed: nil)
        guard let commandBuffer = engine.queue.makeCommandBuffer() else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
