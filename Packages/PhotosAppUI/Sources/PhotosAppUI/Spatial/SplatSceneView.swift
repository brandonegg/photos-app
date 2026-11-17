import MetalKit
import UIKit
import simd

/// What the viewer needs from a view that shows a spatial scene (either renderer).
@MainActor
protocol SpatialSceneDisplay: MTKView {
    /// Set to steer the view by hand (tests); nil follows the iPhone's motion.
    var manualLook: SIMD2<Float>? { get set }
    var averageGPUTime: Double { get }
    func whenFirstFrameShown(_ action: @escaping () -> Void)
    func shutDown()
}

extension SpatialSceneView: SpatialSceneDisplay {}

/// Shows a SHARP scene (3D Gaussians) and moves a real 3D camera as the iPhone tilts: the camera
/// slides across and turns to keep looking at the scene, so near things move against far ones and
/// the hidden parts behind them come into view. Draws only while something changes.
@MainActor
final class SplatSceneView: MTKView, MTKViewDelegate, SpatialSceneDisplay {
    private let renderer: SplatRenderer
    private let buffers: SplatRenderer.Buffers
    private let motion = SpatialMotion()
    private let edgeZoom: Float

    var manualLook: SIMD2<Float>? { didSet { needsFrame = true } }
    private var look = SIMD2<Float>(0, 0)
    private var zoom: Float = 1
    private var drawnLook = SIMD2<Float>(9, 9)
    private var drawnZoom: Float = 0
    private var needsFrame = true
    private var appeared: CFTimeInterval?
    private var lastFrame: CFTimeInterval = 0
    private var firstFrame: [() -> Void] = []
    private var hasDrawn = false
    private var gpuTimes: [Double] = []
    private var didTuneResolution = false
    private(set) var averageGPUTime = 0.0

    init?(cloud: GaussianCloud) {
        guard let renderer = SplatRenderer.shared, let buffers = renderer.buffers(for: cloud) else { return nil }
        self.renderer = renderer
        self.buffers = buffers
        edgeZoom = SplatRenderer.edgeZoom(for: cloud)
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = SplatRenderer.pixelFormat
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        isOpaque = true
        isUserInteractionEnabled = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func appWillResignActive() { setRunning(false) }
    @objc private func appDidBecomeActive() { setRunning(window != nil) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setRunning(window != nil && UIApplication.shared.applicationState == .active)
    }

    private func setRunning(_ running: Bool) {
        isPaused = !running
        if running {
            motion.start(orientation: window?.windowScene?.interfaceOrientation ?? .portrait)
            needsFrame = true
        } else {
            motion.stop()
        }
    }

    func shutDown() { setRunning(false) }

    func whenFirstFrameShown(_ action: @escaping () -> Void) {
        if hasDrawn { action() } else { firstFrame.append(action) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsFrame = true
        motion.set(orientation: window?.windowScene?.interfaceOrientation ?? .portrait)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let started = appeared ?? now
        if appeared == nil { appeared = now; lastFrame = now }
        let dt = Float(min(max(now - lastFrame, 0), 0.1))
        lastFrame = now
        let age = Float(now - started)

        // Opening, as in Photos: the camera eases forward into the scene with a small sweep that shows the depth at once.
        let opening = min(age / 1.4, 1)
        let eased = 1 - pow(1 - opening, 3)
        zoom = 1 + (edgeZoom - 1) * eased
        var target = manualLook ?? motion.look
        if manualLook == nil { target += SIMD2<Float>(0.6, -0.25) * sin(opening * .pi) }
        look += (target - look) * (1 - exp(-dt * 10))

        let moved = simd_distance(look, drawnLook) > 0.001 || abs(zoom - drawnZoom) > 0.0002
        guard needsFrame || moved else { return }
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor, let commandBuffer = renderer.makeCommandBuffer() else { return }
        needsFrame = false
        drawnLook = look
        drawnZoom = zoom
        let size = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        let camera = SplatRenderer.camera(for: buffers.cloud, look: look)
        renderer.encode(buffers, camera: camera, zoom: zoom, size: size, pass: pass, into: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] finished in
            let seconds = finished.gpuEndTime - finished.gpuStartTime
            Task { @MainActor in self?.frameFinished(gpuSeconds: seconds) }
        }
        commandBuffer.commit()
    }

    private func frameFinished(gpuSeconds: Double) {
        if !hasDrawn {
            hasDrawn = true
            let actions = firstFrame
            firstFrame = []
            actions.forEach { $0() }
        }
        guard gpuSeconds > 0, !didTuneResolution else { return }
        gpuTimes.append(gpuSeconds)
        guard gpuTimes.count >= 24 else { return }
        averageGPUTime = gpuTimes.dropFirst(8).reduce(0, +) / Double(gpuTimes.count - 8)
        didTuneResolution = true
        // A slow iPhone draws fewer pixels (splats are soft, so this costs little sharpness).
        if averageGPUTime > 0.014, contentScaleFactor > 2 {
            contentScaleFactor = 2
            needsFrame = true
        }
    }
}
