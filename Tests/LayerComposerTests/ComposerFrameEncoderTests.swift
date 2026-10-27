import CoreGraphics
import Metal
import Testing
import LayerComposer

/// `ComposerFrameEncoder`: base colour, blurred background and foreground composited in order, with
/// a static background rendered and blurred once.
@MainActor
@Suite struct ComposerFrameEncoderTests {
    static let canvas = ComposerCanvas(pixelWidth: 120, pixelHeight: 200, pointWidth: 40, pointHeight: 200.0 / 3.0, backgroundScale: 0.5)
    static let red = SIMD4<Float>(1, 0, 0, 1)
    static let green = SIMD4<Float>(0, 1, 0, 1)

    @Test func compositesBaseUnderTransparentBackground() throws {
        let harness = try Harness(background: SolidBackground(color: .zero), baseColor: Self.red)

        let output = try harness.render(harness.timeline.context(forFrame: 0))

        #expect(output.pixel(x: 0, y: 0, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 60, y: 100, matches: [255, 0, 0, 255]))
        #expect(output.pixel(x: 119, y: 199, matches: [255, 0, 0, 255]))
    }

    @Test func blurredBackgroundCoversBase() throws {
        let harness = try Harness(background: SolidBackground(color: Self.green), baseColor: Self.red)

        let output = try harness.render(harness.timeline.context(forFrame: 0))

        #expect(output.pixel(x: 0, y: 0, matches: [0, 255, 0, 255]))
        #expect(output.pixel(x: 60, y: 100, matches: [0, 255, 0, 255]))
        #expect(output.pixel(x: 119, y: 199, matches: [0, 255, 0, 255]))
    }

    @Test func foregroundOnTop() throws {
        let square = CGRect(x: 10, y: 10, width: 20, height: 20)
        let foreground = try TestImages.image(width: 120, height: 200) { x, y in
            square.contains(CGPoint(x: x, y: y)) ? [0, 0, 255, 255] : .zero
        }
        let harness = try Harness(background: SolidBackground(color: Self.green), baseColor: Self.red, foreground: foreground)

        let output = try harness.render(harness.timeline.context(forFrame: 0))

        #expect(output.pixel(x: 10, y: 10, matches: [0, 0, 255, 255]))
        #expect(output.pixel(x: 29, y: 29, matches: [0, 0, 255, 255]))
        #expect(output.pixel(x: 30, y: 30, matches: [0, 255, 0, 255]))
        #expect(output.pixel(x: 9, y: 10, matches: [0, 255, 0, 255]))
        #expect(output.pixel(x: 100, y: 150, matches: [0, 255, 0, 255]))
    }

    @Test func halfTransparentForegroundBlendsOverBackground() throws {
        let foreground = try TestImages.image(width: 120, height: 200) { _, _ in [0, 0, 128, 128] }
        let harness = try Harness(background: SolidBackground(color: Self.green), baseColor: Self.red, foreground: foreground)

        let output = try harness.render(harness.timeline.context(forFrame: 0))

        #expect(output.pixel(x: 60, y: 100, matches: [0, 127, 128, 255]))
    }

    @Test func rejectsWrongForegroundSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scene = ComposerScene(
            background: SolidBackground(color: Self.green), blur: IdentityBlur(),
            baseColor: Self.red, foreground: try TestImages.clear(width: 121, height: 200)
        )

        #expect(throws: LayerComposerError.foregroundSizeMismatch) {
            _ = try ComposerFrameEncoder(device: device, canvas: Self.canvas, scene: scene)
        }
    }

    @Test func rejectsWrongOutputFormat() throws {
        let harness = try Harness(background: SolidBackground(color: Self.green), baseColor: Self.red)
        let frame = harness.timeline.context(forFrame: 0)
        let float = try harness.makeOutput(pixelFormat: .rgba16Float)
        let wrongSize = try harness.makeOutput(width: 60, height: 100)
        let commandBuffer = try #require(harness.queue.makeCommandBuffer())

        #expect(throws: LayerComposerError.unsupportedOutput) {
            try harness.encoder.encode(frame, into: commandBuffer, output: float)
        }
        #expect(throws: LayerComposerError.unsupportedOutput) {
            try harness.encoder.encode(frame, into: commandBuffer, output: wrongSize)
        }
    }

    @Test func staticBackgroundEncodedOnce() throws {
        let background = SolidBackground(color: Self.green, isAnimated: false)
        let blur = IdentityBlur()
        let harness = try Harness(background: background, blur: blur, baseColor: Self.red)

        let outputs = try (0..<10).map { try harness.render(harness.timeline.context(forFrame: $0)) }

        #expect(harness.encoder.isStatic)
        #expect(background.encodeCount == 1)
        #expect(blur.encodeCount == 1)
        #expect(outputs.allSatisfy { $0 == outputs[0] })
        #expect(outputs[9].pixel(x: 60, y: 100, matches: [0, 255, 0, 255]))
    }

    @Test func animatedBackgroundEncodedEveryFrame() throws {
        let background = SolidBackground(color: Self.green, isAnimated: true)
        let blur = IdentityBlur()
        let harness = try Harness(background: background, blur: blur, baseColor: Self.red)

        for index in 0..<10 {
            _ = try harness.render(harness.timeline.context(forFrame: index))
        }

        #expect(!harness.encoder.isStatic)
        #expect(background.encodeCount == 10)
        #expect(blur.encodeCount == 10)
    }

    @Test func backgroundTargetsAreHalfResolution() throws {
        let background = TargetRecordingBackground()
        let harness = try Harness(background: background, baseColor: Self.red)

        _ = try harness.render(harness.timeline.context(forFrame: 0))

        #expect(background.targetSize == MTLSize(width: 60, height: 100, depth: 1))
        #expect(background.targetFormat == .bgra8Unorm)
    }
}

/// Records the target the encoder hands to the background.
@MainActor
private final class TargetRecordingBackground: BackgroundLayer {
    let isAnimated = false
    var targetSize: MTLSize?
    var targetFormat: MTLPixelFormat?

    func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        targetSize = MTLSize(width: target.width, height: target.height, depth: target.depth)
        targetFormat = target.pixelFormat
    }
}

extension MTLSize: @retroactive Equatable {
    public static func == (lhs: MTLSize, rhs: MTLSize) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.depth == rhs.depth
    }
}

@MainActor
private struct Harness {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let encoder: ComposerFrameEncoder
    let output: MTLTexture
    let timeline = ComposerTimeline(framesPerSecond: 30, duration: 1)

    init(background: any BackgroundLayer, blur: any BlurStage = IdentityBlur(), baseColor: SIMD4<Float>, foreground: CGImage? = nil) throws {
        let canvas = ComposerFrameEncoderTests.canvas
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        let scene = ComposerScene(
            background: background, blur: blur, baseColor: baseColor,
            foreground: try foreground ?? TestImages.clear(width: canvas.pixelWidth, height: canvas.pixelHeight)
        )
        encoder = try ComposerFrameEncoder(device: device, canvas: canvas, scene: scene)
        output = try Self.makeTexture(device: device, width: canvas.pixelWidth, height: canvas.pixelHeight, pixelFormat: .bgra8Unorm)
    }

    func render(_ frame: ComposerFrame) throws -> TextureReadback {
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(frame, into: commandBuffer, output: output)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        return try TextureReadback(output, queue: queue)
    }

    func makeOutput(width: Int = 120, height: Int = 200, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws -> MTLTexture {
        try Self.makeTexture(device: device, width: width, height: height, pixelFormat: pixelFormat)
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
