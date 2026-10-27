import Metal
import QuartzCore
import SwiftUI
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Live preview of a composition: the same per-frame encode as the exporters (so the preview is
/// what gets exported), looping the timeline on a display link, drawn aspect-fit into a
/// `CAMetalLayer` at the view's size × screen scale. It pauses while the app is in the background.
///
/// The device, canvas and timeline are fixed for the view's identity; `isAnimating` and `makeScene`
/// may change on update (a new `makeScene` is used from the next appearance).
public struct ComposerPreviewView: View {
    private let device: MTLDevice
    private let canvas: ComposerCanvas
    private let timeline: ComposerTimeline
    private let isAnimating: Bool
    private let makeScene: @MainActor () throws -> ComposerScene

    /// makeScene is called once per appearance (fresh background state). isAnimating false — or a
    /// static scene — renders frame 0 once and stops the display link.
    public init(
        device: MTLDevice, canvas: ComposerCanvas, timeline: ComposerTimeline,
        isAnimating: Bool, makeScene: @escaping @MainActor () throws -> ComposerScene
    ) {
        self.device = device
        self.canvas = canvas
        self.timeline = timeline
        self.isAnimating = isAnimating
        self.makeScene = makeScene
    }

    public var body: some View {
        PreviewSurface(
            device: device, canvas: canvas, timeline: timeline, isAnimating: isAnimating, makeScene: makeScene
        )
    }
}

// MARK: - Controller

/// Owns the frame renderer, the display link and the schedule for one preview view.
@MainActor
final class PreviewController {
    private static let logger = Logger(subsystem: "LayerComposer", category: "ComposerPreviewView")

    private let device: MTLDevice
    private let canvas: ComposerCanvas
    private let timeline: ComposerTimeline
    private let commandQueue: MTLCommandQueue?
    private var makeScene: @MainActor () throws -> ComposerScene
    private var schedule: PreviewFrameSchedule
    private var renderer: PreviewFrameRenderer?
    /// `makeScene` or the encoder failed for this appearance: render nothing until the next one.
    private var sceneFailed = false
    private weak var view: PreviewMetalView?
    private var displayLink: CADisplayLink?
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        device: MTLDevice, canvas: ComposerCanvas, timeline: ComposerTimeline,
        isAnimating: Bool, makeScene: @escaping @MainActor () throws -> ComposerScene
    ) {
        self.device = device
        self.canvas = canvas
        self.timeline = timeline
        self.makeScene = makeScene
        commandQueue = device.makeCommandQueue()
        schedule = PreviewFrameSchedule(isAnimating: isAnimating)
        observeAppLifecycle()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to view: PreviewMetalView) {
        self.view = view
        view.metalLayer.device = device
        view.onWindowChange = { [weak self] inWindow in
            if inWindow { self?.appear() } else { self?.disappear() }
        }
        view.onDrawableResize = { [weak self] in
            self?.schedule.redraw()
            self?.updateDisplayLink()
        }
        if view.isInWindow { appear() }
    }

    func update(isAnimating: Bool, makeScene: @escaping @MainActor () throws -> ComposerScene) {
        self.makeScene = makeScene
        schedule.isAnimating = isAnimating
        updateDisplayLink()
    }

    func dismantle() {
        disappear()
        view = nil
    }

    // MARK: App lifecycle

    /// App-wide notifications rather than `scenePhase`, which reads `.background` outside a SwiftUI
    /// scene (UIKit hosting, tests). GPU work is refused in the background anyway.
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(true) }
            },
        ]
        #endif
    }

    private func setActive(_ isActive: Bool) {
        guard schedule.isActive != isActive else { return }
        schedule.isActive = isActive
        if isActive { prepareRenderer() }
        updateDisplayLink()
    }

    // MARK: Appearance

    private func appear() {
        guard let view, displayLink == nil else { return }
        schedule.restart()
        sceneFailed = false
        if schedule.isActive { prepareRenderer() }
        let target = DisplayLinkTarget(controller: self)
        #if canImport(UIKit)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        #else
        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        #endif
        let fps = Float(timeline.framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDisplayLink()
    }

    private func disappear() {
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
    }

    /// Builds the renderer from a fresh scene unless there is one, or this appearance already failed.
    private func prepareRenderer() {
        guard renderer == nil, !sceneFailed, view?.isInWindow == true else { return }
        do {
            let renderer = try PreviewFrameRenderer(device: device, canvas: canvas, scene: makeScene())
            schedule.isStatic = renderer.isStatic
            schedule.redraw()
            self.renderer = renderer
        } catch {
            sceneFailed = true
            Self.logger.error("ComposerPreviewView renders nothing: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateDisplayLink() {
        displayLink?.isPaused = renderer == nil || !schedule.wantsTicks
    }

    // MARK: Frames

    fileprivate func tick(at timestamp: CFTimeInterval) {
        switch schedule.tick(at: timestamp) {
        case .render(let time):
            render(at: time)
        case .skip, .stop:
            break
        }
        updateDisplayLink()
    }

    /// Encodes and commits one frame. Called only while fewer than `maxFramesInFlight` frames are
    /// on the GPU, so `nextDrawable` does not wait on our own frames.
    private func render(at time: Double) {
        guard let renderer, let commandQueue, let layer = view?.metalLayer,
              layer.drawableSize.width >= 1, layer.drawableSize.height >= 1,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        commandBuffer.label = "LayerComposer.preview"
        do {
            try renderer.encode(timeline.context(atTime: time), into: commandBuffer, drawable: drawable.texture)
        } catch {
            self.renderer = nil
            sceneFailed = true
            Self.logger.error("ComposerPreviewView stopped: \(String(describing: error), privacy: .public)")
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self, weak renderer] buffer in
            let error = buffer.error.map { String(describing: $0) }
            Task { @MainActor in
                self?.frameCompleted(renderer: renderer, error: error)
            }
        }
        commandBuffer.commit()
        schedule.frameCommitted()
    }

    private func frameCompleted(renderer completed: PreviewFrameRenderer?, error: String?) {
        schedule.frameCompleted()
        if let error {
            Self.logger.error("ComposerPreviewView frame failed: \(error, privacy: .public)")
            // A failed first frame leaves a static scene's cached background unusable (e.g. GPU work
            // refused in the background): rebuild the scene when active again.
            if let completed, completed === renderer {
                renderer = nil
                schedule.restart()
                if schedule.isActive { prepareRenderer() }
            }
        }
        updateDisplayLink()
    }
}

/// The display link's target; weak to the controller so the link does not keep it alive.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var controller: PreviewController?

    init(controller: PreviewController) {
        self.controller = controller
    }

    @objc func tick(_ link: CADisplayLink) {
        controller?.tick(at: link.timestamp)
    }
}

// MARK: - Platform view

#if canImport(UIKit)

private struct PreviewSurface: UIViewRepresentable {
    let device: MTLDevice
    let canvas: ComposerCanvas
    let timeline: ComposerTimeline
    let isAnimating: Bool
    let makeScene: @MainActor () throws -> ComposerScene

    func makeCoordinator() -> PreviewController {
        PreviewController(device: device, canvas: canvas, timeline: timeline, isAnimating: isAnimating, makeScene: makeScene)
    }

    func makeUIView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PreviewMetalView, context: Context) {
        context.coordinator.update(isAnimating: isAnimating, makeScene: makeScene)
    }

    static func dismantleUIView(_ view: PreviewMetalView, coordinator: PreviewController) {
        coordinator.dismantle()
    }
}

/// A view backed by a `CAMetalLayer` whose drawable tracks bounds × screen scale.
final class PreviewMetalView: UIView {
    var onWindowChange: ((Bool) -> Void)?
    var onDrawableResize: (() -> Void)?

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer {
        // layerClass guarantees the type.
        layer as! CAMetalLayer
    }

    var isInWindow: Bool { window != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        configure(metalLayer)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: PreviewMetalView, _) in
            view.updateDrawableSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        onWindowChange?(isInWindow)
    }

    private func updateDrawableSize() {
        resizeDrawable(of: metalLayer, bounds: bounds, scale: traitCollection.displayScale, onResize: onDrawableResize)
    }
}

#elseif canImport(AppKit)

private struct PreviewSurface: NSViewRepresentable {
    let device: MTLDevice
    let canvas: ComposerCanvas
    let timeline: ComposerTimeline
    let isAnimating: Bool
    let makeScene: @MainActor () throws -> ComposerScene

    func makeCoordinator() -> PreviewController {
        PreviewController(device: device, canvas: canvas, timeline: timeline, isAnimating: isAnimating, makeScene: makeScene)
    }

    func makeNSView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: PreviewMetalView, context: Context) {
        context.coordinator.update(isAnimating: isAnimating, makeScene: makeScene)
    }

    static func dismantleNSView(_ view: PreviewMetalView, coordinator: PreviewController) {
        coordinator.dismantle()
    }
}

/// A view backed by a `CAMetalLayer` whose drawable tracks bounds × backing scale.
final class PreviewMetalView: NSView {
    var onWindowChange: ((Bool) -> Void)?
    var onDrawableResize: (() -> Void)?

    let metalLayer = CAMetalLayer()

    var isInWindow: Bool { window != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        configure(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        onWindowChange?(isInWindow)
    }

    private func updateDrawableSize() {
        resizeDrawable(of: metalLayer, bounds: bounds, scale: window?.backingScaleFactor ?? 1, onResize: onDrawableResize)
    }
}

#endif

/// Transparent, sRGB-tagged `.bgra8Unorm` layer — the encoder writes sRGB-encoded values.
@MainActor
private func configure(_ layer: CAMetalLayer) {
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.isOpaque = false
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
}

/// Sets the drawable to `bounds` × `scale` pixels and reports a change.
@MainActor
private func resizeDrawable(of layer: CAMetalLayer, bounds: CGRect, scale: CGFloat, onResize: (() -> Void)?) {
    layer.contentsScale = scale
    let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    guard size != layer.drawableSize else { return }
    layer.drawableSize = size
    onResize?()
}
