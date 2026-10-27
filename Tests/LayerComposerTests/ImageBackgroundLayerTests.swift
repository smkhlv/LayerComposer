import Testing
import LayerComposer

/// `ImageBackgroundLayer`: a static photo, aspect-filled and centred in the target.
@MainActor
@Suite struct ImageBackgroundLayerTests {
    static let frame = ComposerTimeline.tenSeconds.context(forFrame: 0)

    @Test func imageLayerIsStatic() throws {
        let render = try BackgroundLayerRender()
        let layer = try ImageBackgroundLayer(device: render.device, image: TestImages.clear(width: 4, height: 4))

        #expect(!layer.isAnimated)
    }

    @Test func aspectFillsAndCentres() throws {
        let render = try BackgroundLayerRender()
        // Top half red, bottom half blue, a green column at the far left that aspect-fill crops away.
        let image = try TestImages.image(width: 100, height: 100) { x, y in
            if x < 10 { return [0, 255, 0, 255] }
            return y < 50 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
        let layer = try ImageBackgroundLayer(device: render.device, image: image)

        let output = try render.render(layer, frame: Self.frame, width: 180, height: 320)

        #expect(output.pixel(x: 90, y: 4, matches: [255, 0, 0, 255], tolerance: 2))
        #expect(output.pixel(x: 90, y: 315, matches: [0, 0, 255, 255], tolerance: 2))
        // 320×320 after the fill, 70 px cropped on each side: the green column (0..<32 px) is gone.
        #expect(output.pixel(x: 0, y: 80, matches: [255, 0, 0, 255], tolerance: 2))
        for (x, y) in [(0, 0), (179, 0), (0, 319), (179, 319)] {
            #expect(output.rgba(x: x, y: y).w == 255, "transparent edge at (\(x), \(y))")
        }
    }
}
