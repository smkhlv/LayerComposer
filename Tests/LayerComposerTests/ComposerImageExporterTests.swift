import CoreGraphics
import Metal
import Testing
import LayerComposer

/// `ComposerImageExporter`: one frame as a canvas-sized `CGImage`, pixel for pixel what the frame
/// encoder draws.
@MainActor
@Suite struct ComposerImageExporterTests {
    static let canvas = ComposerCanvas(pixelWidth: 270, pixelHeight: 480, pointWidth: 90, pointHeight: 160, backgroundScale: 0.5)

    @Test func stillIsCanvasSize() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let exporter = ComposerImageExporter(device: device)

        let image = try await exporter.render(scene: try Self.scene(), canvas: Self.canvas)

        #expect(image.width == 270)
        #expect(image.height == 480)
    }

    @Test func stillMatchesVideoFrameZero() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let scene = try Self.scene()
        let frame = ComposerTimeline(framesPerSecond: 30, duration: 1).context(forFrame: 0)
        let encoder = try ComposerFrameEncoder(device: device, canvas: Self.canvas, scene: scene)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 270, height: 480, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(frame, into: commandBuffer, output: output)
        commandBuffer.commitAndWait()
        let expected = try TextureReadback(output, queue: queue)

        let image = try await ComposerImageExporter(device: device).render(scene: scene, canvas: Self.canvas, frame: frame)

        #expect(try ImagePixels.bgra(image) == expected.pixels)
        #expect(expected.pixel(x: 20, y: 20, matches: [0, 0, 255, 255]))
        #expect(expected.pixel(x: 200, y: 400, matches: [0, 255, 0, 255]))
    }

    /// Green background, a blue foreground square in the top-left corner, red base.
    static func scene() throws -> ComposerScene {
        let foreground = try TestImages.image(width: 270, height: 480) { x, y in
            x < 100 && y < 100 ? [0, 0, 255, 255] : .zero
        }
        return ComposerScene(
            background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true), blur: IdentityBlur(),
            baseColor: [1, 0, 0, 1], foreground: foreground
        )
    }
}
