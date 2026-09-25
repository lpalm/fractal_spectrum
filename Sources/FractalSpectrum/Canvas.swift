import AppKit
import MetalKit
import SwiftUI
import FractalKit

/// Metal view that turns mouse, trackpad and keyboard input into camera motion.
final class FractalMTKView: MTKView {
    weak var model: AppModel?
    private var lastDrag: (point: CGPoint, time: TimeInterval)?
    private var dragVelocity = SIMD2<Double>(0, 0)
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        updateFrameBudget()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrameBudget() }
        }
    }

    /// Iteration budget per frame: most of the display's frame interval.
    private func updateFrameBudget() {
        let hz = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        model?.renderer.budgetMs = 1000 / max(hz, 30) * 0.72
    }

    private var scale: Double { Double(window?.backingScaleFactor ?? 2) }
    private var pixelSize: (Int, Int) { (Int(drawableSize.width), Int(drawableSize.height)) }

    /// Drawable pixel coordinates (origin top-left) of a point in view coordinates.
    private func pixel(_ p: CGPoint) -> SIMD2<Double> {
        SIMD2(Double(p.x) * scale, Double(bounds.height - p.y) * scale)
    }

    private func location(_ e: NSEvent) -> SIMD2<Double> { pixel(convert(e.locationInWindow, from: nil)) }

    override func scrollWheel(with e: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        let zoomModifier = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        if e.hasPreciseScrollingDeltas && !zoomModifier {
            // trackpad: two-finger scroll pans, momentum included
            model.camera.pan(pixels: SIMD2(Double(e.scrollingDeltaX), Double(e.scrollingDeltaY)) * scale, width: w, height: h)
            model.userInteracted()
        } else {
            let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) * 0.02 : Double(e.scrollingDeltaY) * 0.18
            model.camera.zoom(log2Factor: -dy, at: location(e), width: w, height: h, animated: true)
            model.userInteracted()
        }
    }

    override func magnify(with e: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        model.camera.zoom(log2Factor: -log2(max(0.2, 1 + Double(e.magnification))), at: location(e),
                          width: w, height: h, animated: false)
        model.userInteracted()
    }

    override func rotate(with e: NSEvent) {
        guard let model else { return }
        model.camera.rotate(by: Double(e.rotation) * .pi / 180)
        model.userInteracted()
    }

    override func mouseDown(with e: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        if e.clickCount == 2 {
            let (w, h) = pixelSize
            let f = e.modifierFlags.contains(.option) ? 2.0 : -2.0
            model.camera.zoom(log2Factor: f, at: location(e), width: w, height: h, animated: true)
            model.userInteracted()
            return
        }
        if e.modifierFlags.contains(.option) && model.formula.family == .mandelbrot && !model.formula.julia {
            model.pickJulia(atPixel: location(e))
            return
        }
        model.camera.stopMotion()
        model.camera.cancelFlight()
        dragging = true
        lastDrag = (e.locationInWindow, e.timestamp)
        dragVelocity = .zero
    }

    override func mouseDragged(with e: NSEvent) {
        guard let model, dragging, let last = lastDrag else { return }
        let (w, h) = pixelSize
        let d = SIMD2(Double(e.locationInWindow.x - last.point.x), Double(last.point.y - e.locationInWindow.y)) * scale
        model.camera.pan(pixels: d, width: w, height: h)
        let dt = max(e.timestamp - last.time, 1e-3)
        dragVelocity = dragVelocity * 0.5 + (d / dt) * 0.5
        lastDrag = (e.locationInWindow, e.timestamp)
        model.userInteracted()
    }

    override func mouseUp(with e: NSEvent) {
        guard let model, dragging else { return }
        dragging = false
        if let last = lastDrag, e.timestamp - last.time < 0.06, simdLength(dragVelocity) > 200 {
            model.camera.fling(velocity: dragVelocity)
        }
        lastDrag = nil
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        model.camera.zoom(log2Factor: 2, at: location(e), width: w, height: h, animated: true)
        model.userInteracted()
    }

    override func keyDown(with e: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        let c = SIMD2(Double(w), Double(h)) * 0.5
        let panStep = Double(min(w, h)) * 0.12
        switch e.keyCode {
        case 123: model.camera.fling(velocity: SIMD2(panStep * 6, 0))      // left
        case 124: model.camera.fling(velocity: SIMD2(-panStep * 6, 0))     // right
        case 125: model.camera.fling(velocity: SIMD2(0, -panStep * 6))     // down
        case 126: model.camera.fling(velocity: SIMD2(0, panStep * 6))      // up
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "=", "+": model.camera.zoom(log2Factor: -1, at: c, width: w, height: h, animated: true)
            case "-", "_": model.camera.zoom(log2Factor: 1, at: c, width: w, height: h, animated: true)
            case "q": model.camera.rotate(by: .pi / 12, animated: true)
            case "e": model.camera.rotate(by: -.pi / 12, animated: true)
            case "h": model.goHome()
            case "b":
                model.addBookmark()
                return
            case " ": model.showUI.toggle()
            case "j": model.toggleJulia()
            case "c": model.cyclePalette(1)
            case "x": model.cyclePalette(-1)
            case "]": model.scaleIterations(2)
            case "[": model.scaleIterations(0.5)
            case "l": model.toggleLighting()
            case "f": window?.toggleFullScreen(nil)
            case "p": model.autopilot.toggle()
            case "t":
                if model.touring { model.stopTour() } else { model.startTour() }
                return
            default: super.keyDown(with: e)
            }
        }
        model.userInteracted()
    }
}

@inline(__always) func simdLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

/// SwiftUI wrapper around the Metal canvas.
struct FractalCanvas: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> FractalMTKView {
        let v = FractalMTKView(frame: .zero, device: GPU.shared.device)
        v.model = model
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.preferredFramesPerSecond = 120
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = v.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 3
            layer.displaySyncEnabled = true
            layer.allowsNextDrawableTimeout = true
        }
        v.delegate = model.renderer
        return v
    }

    func updateNSView(_ nsView: FractalMTKView, context: Context) {}
}
