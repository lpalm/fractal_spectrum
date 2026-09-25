import AppKit
import MetalKit
import SwiftUI
import simd
import Carbon.HIToolbox
import FractalKit

/// Metal view that turns mouse, trackpad and keyboard input into camera motion.
final class FractalMTKView: MTKView {
    weak var model: AppModel?
    private var lastDrag: (point: CGPoint, time: TimeInterval)?
    private var dragVelocity = SIMD2<Double>(0, 0)
    private var dragging = false

    /// Set by ⌥-scroll zooming, so that the Julia preview stays hidden until ⌥ is released.
    private var juliaHoverSuppressed = false

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

    /// Switches the layer between standard sRGB and extended-range linear Display P3 output.
    func configureOutput(hdr: Bool) {
        guard let layer = layer as? CAMetalLayer else { return }
        if hdr {
            colorPixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = true
        } else {
            colorPixelFormat = .bgra8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.wantsExtendedDynamicRangeContent = false
        }
    }

    /// Live EDR headroom of the window's screen (1 when HDR is off or unsupported).
    var edrHeadroom: Float {
        Float(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
    }

    /// GPU time per frame for compute passes: most of the display's frame interval.
    private func updateFrameBudget() {
        let hz = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        model?.renderer.frameBudgetMs = 1000 / max(hz, 30) * 0.72
    }

    /// Drawable pixels per point.
    private var backingScale: Double { Double(window?.backingScaleFactor ?? 2) }
    private var pixelSize: (Int, Int) { (Int(drawableSize.width), Int(drawableSize.height)) }

    /// Drawable pixel coordinates (origin top-left) of a point in view coordinates.
    private func pixel(_ point: CGPoint) -> SIMD2<Double> {
        SIMD2(Double(point.x) * backingScale, Double(bounds.height - point.y) * backingScale)
    }

    /// Drawable pixel coordinates of an event's location.
    private func pixel(of event: NSEvent) -> SIMD2<Double> { pixel(convert(event.locationInWindow, from: nil)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event.modifierFlags) }

    override func mouseExited(with event: NSEvent) {
        model?.juliaHover = nil
        model?.orbitHover = nil
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHover(event.modifierFlags)
    }

    private func updateHover(_ flags: NSEvent.ModifierFlags) {
        // ⌥ can be released while another app is active, without a flagsChanged here
        if !flags.contains(.option) { juliaHoverSuppressed = false }
        updateJuliaHover(option: flags.contains(.option))
        updateOrbit(shift: flags.contains(.shift) && !flags.contains(.command))
    }

    /// Shows the orbit of the point under the pointer while ⇧ is held.
    private func updateOrbit(shift: Bool) {
        guard let model, let window else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard shift, bounds.contains(pointer) else {
            if model.orbitHover != nil { model.orbitHover = nil }
            return
        }
        model.showOrbit(atPixel: pixel(pointer), scale: backingScale)
    }

    /// Shows the Julia set of the parameter under the pointer while ⌥ is held over the Mandelbrot set.
    private func updateJuliaHover(option: Bool) {
        guard let model, let window else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard option, !juliaHoverSuppressed, model.formula.family == .mandelbrot, !model.formula.julia,
              bounds.contains(pointer) else {
            if model.juliaHover != nil { model.juliaHover = nil }
            return
        }
        let (w, h) = pixelSize
        let c = model.camera.view.point(atPixel: pixel(pointer), width: w, height: h, flipY: false)
        model.juliaHover = JuliaHover(point: CGPoint(x: pointer.x, y: bounds.height - pointer.y), re: c.re.doubleValue,
                                      im: c.im.doubleValue)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        let zoomModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        if event.modifierFlags.contains(.option) {
            juliaHoverSuppressed = true
            model.juliaHover = nil
        }
        if event.hasPreciseScrollingDeltas && !zoomModifier {
            // trackpad: two-finger scroll pans, momentum included
            model.camera.pan(pixels: SIMD2(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)) * backingScale, width: w, height: h)
            model.userInteracted()
        } else {
            let dy = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY) * 0.02 : Double(event.scrollingDeltaY) * 0.18
            model.camera.zoom(log2Factor: -dy, at: pixel(of: event), width: w, height: h, animated: true)
            model.userInteracted()
        }
    }

    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        model.camera.zoom(log2Factor: -log2(max(0.2, 1 + Double(event.magnification))), at: pixel(of: event),
                          width: w, height: h, animated: false)
        model.userInteracted()
    }

    override func rotate(with event: NSEvent) {
        guard let model else { return }
        model.camera.rotate(by: Double(event.rotation) * .pi / 180)
        model.userInteracted()
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let (w, h) = pixelSize
            let log2Factor = event.modifierFlags.contains(.option) ? 2.0 : -2.0
            model.camera.zoom(log2Factor: log2Factor, at: pixel(of: event), width: w, height: h, animated: true)
            model.userInteracted()
            return
        }
        if event.modifierFlags.contains(.option) && model.formula.family == .mandelbrot && !model.formula.julia {
            model.pickJulia(atPixel: pixel(of: event))
            return
        }
        model.camera.stopMotion()
        model.camera.cancelFlight()
        dragging = true
        lastDrag = (event.locationInWindow, event.timestamp)
        dragVelocity = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, dragging, let last = lastDrag else { return }
        let (w, h) = pixelSize
        let d = SIMD2(Double(event.locationInWindow.x - last.point.x), Double(last.point.y - event.locationInWindow.y)) * backingScale
        model.camera.pan(pixels: d, width: w, height: h)
        let dt = max(event.timestamp - last.time, 1e-3)
        dragVelocity = dragVelocity * 0.5 + (d / dt) * 0.5
        lastDrag = (event.locationInWindow, event.timestamp)
        model.userInteracted()
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, dragging else { return }
        dragging = false
        // a release while still moving flings the content
        if let last = lastDrag, event.timestamp - last.time < 0.06, simd_length(dragVelocity) > 200 {
            model.camera.fling(velocity: dragVelocity)
        }
        lastDrag = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        model.camera.zoom(log2Factor: 2, at: pixel(of: event), width: w, height: h, animated: true)
        model.userInteracted()
    }

    /// Keeps the layer format and EDR headroom in line with the HDR setting (called every frame).
    func syncOutputFormat() {
        guard let model else { return }
        let wantHDR = model.hdrEnabled
        if wantHDR != (colorPixelFormat == .rgba16Float) { configureOutput(hdr: wantHDR) }
        model.renderer.hdrHeadroom = wantHDR ? edrHeadroom : nil
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let (w, h) = pixelSize
        let center = SIMD2(Double(w), Double(h)) * 0.5
        let flingSpeed = Double(min(w, h)) * 0.72   // pixels per second
        switch Int(event.keyCode) {
        case kVK_LeftArrow: model.camera.fling(velocity: SIMD2(flingSpeed, 0))
        case kVK_RightArrow: model.camera.fling(velocity: SIMD2(-flingSpeed, 0))
        case kVK_DownArrow: model.camera.fling(velocity: SIMD2(0, -flingSpeed))
        case kVK_UpArrow: model.camera.fling(velocity: SIMD2(0, flingSpeed))
        case kVK_Escape:
            if model.showHelp { model.showHelp = false } else { super.keyDown(with: event) }
            return
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "=", "+": model.camera.zoom(log2Factor: -1, at: center, width: w, height: h, animated: true)
            case "-", "_": model.camera.zoom(log2Factor: 1, at: center, width: w, height: h, animated: true)
            case "q": model.camera.rotate(by: .pi / 12, animated: true)
            case "e": model.camera.rotate(by: -.pi / 12, animated: true)
            case "h": model.goHome()
            case " ": model.showUI.toggle()
            case "j": model.toggleJulia()
            case "c": model.cyclePalette(1)
            case "x": model.cyclePalette(-1)
            case "]": model.scaleIterations(2)
            case "[": model.scaleIterations(0.5)
            case "l": model.toggleLighting()
            case "f": window?.toggleFullScreen(nil)
            case "p": model.autopilotEngaged.toggle()
            // the keys below leave the tour and the autopilot running
            case "m": model.findMinibrot(); return
            case "b": model.addBookmark(); return
            case ",", "<": model.scaleAutopilotSpeed(1 / 1.4); return
            case ".", ">": model.scaleAutopilotSpeed(1.4); return
            case "t": model.toggleTour(); return
            case "?", "/": model.showHelp.toggle(); return
            default: super.keyDown(with: event)
            }
        }
        model.userInteracted()
    }
}

/// SwiftUI wrapper around the Metal canvas.
struct FractalCanvas: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> FractalMTKView {
        let view = FractalMTKView(frame: .zero, device: GPU.shared.device)
        view.model = model
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 3
            layer.displaySyncEnabled = true
            layer.allowsNextDrawableTimeout = true
        }
        view.delegate = model.renderer
        return view
    }

    func updateNSView(_ nsView: FractalMTKView, context: Context) {}
}
