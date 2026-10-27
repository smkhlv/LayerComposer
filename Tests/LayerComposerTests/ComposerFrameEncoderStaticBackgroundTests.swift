import Metal
import Testing
import LayerComposer

/// The cached static background is trusted only once the command buffer that rendered it runs: a
/// frame whose command buffer never reaches the GPU must not leave the background empty for good.
@MainActor
@Suite struct ComposerFrameEncoderStaticBackgroundTests {
    static let canvas = ComposerCanvas(pixelWidth: 120, pixelHeight: 200, pointWidth: 40, pointHeight: 200.0 / 3.0, backgroundScale: 0.5)

    @Test func staticBackgroundRetriesAfterDroppedFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let background = SolidBackground(color: [0, 1, 0, 1], isAnimated: false)
        let scene = ComposerScene(
            background: background, blur: IdentityBlur(), baseColor: [1, 0, 0, 1],
            foreground: try TestImages.clear(width: 120, height: 200)
        )
        let encoder = try ComposerFrameEncoder(device: device, canvas: Self.canvas, scene: scene)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 120, height: 200, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let timeline = ComposerTimeline(framesPerSecond: 30, duration: 1)

        // Frame 0 is encoded, then its command buffer is dropped without being committed.
        let dropped = try #require(queue.makeCommandBuffer())
        try encoder.encode(timeline.context(forFrame: 0), into: dropped, output: output)

        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(timeline.context(forFrame: 1), into: commandBuffer, output: output)
        commandBuffer.commitAndWait()
        let frame = try TextureReadback(output, queue: queue)

        #expect(background.encodeCount == 2)
        #expect(frame.pixel(x: 60, y: 100, matches: [0, 255, 0, 255]))

        // Once a committed frame has rendered it, the background is reused.
        let next = try #require(queue.makeCommandBuffer())
        try encoder.encode(timeline.context(forFrame: 2), into: next, output: output)
        next.commitAndWait()
        #expect(background.encodeCount == 2)
        #expect(try TextureReadback(output, queue: queue).pixel(x: 60, y: 100, matches: [0, 255, 0, 255]))
    }

    @Test func staticBackgroundEncodedOnceWhileFramesInFlight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let background = SolidBackground(color: [0, 1, 0, 1], isAnimated: false)
        let scene = ComposerScene(
            background: background, blur: IdentityBlur(), baseColor: [1, 0, 0, 1],
            foreground: try TestImages.clear(width: 120, height: 200)
        )
        let encoder = try ComposerFrameEncoder(device: device, canvas: Self.canvas, scene: scene)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 120, height: 200, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let timeline = ComposerTimeline(framesPerSecond: 30, duration: 1)

        // Committed but not yet awaited: later frames on the same queue reuse the pending background.
        let outputs = try (0..<3).map { index in
            let output = try #require(device.makeTexture(descriptor: descriptor))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            try encoder.encode(timeline.context(forFrame: index), into: commandBuffer, output: output)
            commandBuffer.commit()
            return output
        }

        #expect(background.encodeCount == 1)
        for output in outputs {
            #expect(try TextureReadback(output, queue: queue).pixel(x: 60, y: 100, matches: [0, 255, 0, 255]))
        }
    }
}
