import Metal
import Testing
@testable import LayerComposer

/// `PreviewFrameRenderer`: the composited canvas drawn aspect-fit into a drawable of any size, the
/// rest cleared.
@MainActor
@Suite struct PreviewFrameRendererTests {
    static let canvas = ComposerCanvas(pixelWidth: 90, pixelHeight: 160, pointWidth: 30, pointHeight: 160.0 / 3.0, backgroundScale: 0.5)
    static let timeline = ComposerTimeline(framesPerSecond: 30, duration: 1)

    @Test func drawsCanvasAspectFitIntoWiderDrawable() throws {
        let harness = try Harness()

        // 90×160 fits 200×160 as 90×160 centred at x 55..<145.
        let output = try harness.render(drawableWidth: 200, drawableHeight: 160)

        #expect(output.pixel(x: 100, y: 80, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 57, y: 2, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 142, y: 157, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 52, y: 80, matches: .zero))
        #expect(output.pixel(x: 148, y: 80, matches: .zero))
    }

    @Test func drawsCanvasAspectFitIntoTallerDrawable() throws {
        let harness = try Harness()

        // 90×160 fits 45×200 as 45×80 centred at y 60..<140.
        let output = try harness.render(drawableWidth: 45, drawableHeight: 200)

        #expect(output.pixel(x: 22, y: 100, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 22, y: 57, matches: .zero))
        #expect(output.pixel(x: 22, y: 143, matches: .zero))
    }

    @Test func reportsStaticScene() throws {
        let harness = try Harness(isAnimated: false)
        let animated = try Harness(isAnimated: true)

        #expect(harness.renderer.isStatic)
        #expect(!animated.renderer.isStatic)
    }

    @MainActor
    struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: PreviewFrameRenderer

        init(isAnimated: Bool = false) throws {
            device = try #require(MTLCreateSystemDefaultDevice())
            queue = try #require(device.makeCommandQueue())
            let scene = ComposerScene(
                background: SolidBackground(color: [1, 0, 0, 1], isAnimated: isAnimated),
                blur: IdentityBlur(),
                baseColor: .zero,
                foreground: try TestImages.clear(width: canvas.pixelWidth, height: canvas.pixelHeight)
            )
            renderer = try PreviewFrameRenderer(device: device, canvas: canvas, scene: scene)
        }

        func render(drawableWidth: Int, drawableHeight: Int) throws -> TextureReadback {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: drawableWidth, height: drawableHeight, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            let drawable = try #require(device.makeTexture(descriptor: descriptor))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            try renderer.encode(timeline.context(atTime: 0), into: commandBuffer, drawable: drawable)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            try #require(commandBuffer.status == .completed)
            return try TextureReadback(drawable, queue: queue)
        }
    }
}
