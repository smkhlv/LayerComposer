import CoreGraphics
import Testing
import LayerComposer

/// `AmbientGlowLayer`: the card image's own colours extended outwards from the card's edges,
/// fading with distance and looping seamlessly.
@MainActor
@Suite struct AmbientGlowLayerTests {
    /// Background target 180×320; canvas pixel = 2 target pixels.
    static let canvas = ComposerCanvas(pixelWidth: 360, pixelHeight: 640, pointWidth: 120, pointHeight: 640.0 / 3.0, backgroundScale: 0.5)
    /// 200×300 canvas px, centred: x 80...280, y 170...470.
    static let cardRect = CGRect(x: 80, y: 170, width: 200, height: 300)
    static let timeline = ComposerTimeline.tenSeconds

    @Test func ambientLayerIsAnimated() throws {
        let harness = try Harness(cardImage: Self.redBlueCard())

        #expect(harness.layer.isAnimated)
    }

    @Test func leftOfCardIsRed() throws {
        let output = try Harness(cardImage: Self.redBlueCard()).render(frame: 0)

        // 20 canvas px left of the card at its vertical centre: canvas (60, 320).
        let pixel = output.rgba(x: 30, y: 160)
        #expect(pixel.x > pixel.z)
        #expect(pixel.x > 100)
    }

    @Test func rightOfCardIsBlue() throws {
        let output = try Harness(cardImage: Self.redBlueCard()).render(frame: 0)

        // 20 canvas px right of the card: canvas (300, 320).
        let pixel = output.rgba(x: 150, y: 160)
        #expect(pixel.z > pixel.x)
        #expect(pixel.z > 100)
    }

    @Test func farCornerIsDimmerThanNearEdge() throws {
        let output = try Harness(cardImage: Self.redBlueCard()).render(frame: 0)

        let corner = output.rgba(x: 0, y: 0).w
        let nearEdge = output.rgba(x: 39, y: 160).w
        #expect(corner < nearEdge)
        #expect(corner > 0, "the glow still reaches the corner, only dimmer")
        // exp(−d/420) for the corner's ≈ 189 canvas px from the card, breathing at its peak (×1.12).
        let expected = exp(-hypot(80.0 - 1, 170.0 - 1) / 420) * 1.12 * 255
        #expect(abs(Double(corner) - expected) < 4)
    }

    @Test func loopIsSeamless() throws {
        let harness = try Harness(cardImage: Self.redBlueCard())

        let first = try harness.render(frame: 0)
        let wrapped = try harness.render(frame: 300)
        let quarter = try harness.render(frame: 75)

        #expect(first == wrapped)
        #expect(first != quarter, "the glow moves within the loop")
    }

    @Test(arguments: ExtremeImage.allCases)
    func extremeAspectAndTinyImagesRender(_ kind: ExtremeImage) throws {
        let harness = try Harness(cardImage: kind.image())

        let output = try harness.render(frame: 40)

        for y in 0..<output.height {
            for x in 0..<output.width {
                let pixel = output.rgba(x: x, y: y)
                #expect(pixel.x <= pixel.w && pixel.y <= pixel.w && pixel.z <= pixel.w, "not premultiplied at (\(x), \(y))")
            }
        }
        let nearEdge = output.rgba(x: 39, y: 160).w
        if kind == .transparent {
            #expect(nearEdge == 0, "a transparent card leaves the base colour showing")
        } else {
            #expect(nearEdge > 128)
        }
    }

    /// Left half red, right half blue.
    static func redBlueCard() throws -> CGImage {
        try TestImages.image(width: 40, height: 60) { x, _ in x < 20 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
    }
}

enum ExtremeImage: String, CaseIterable, CustomTestStringConvertible {
    case panorama1x400, tiny16, transparent, sixteenBit, cmyk

    var testDescription: String { rawValue }

    func image() throws -> CGImage {
        switch self {
        case .panorama1x400:
            return try TestImages.image(width: 1, height: 400) { _, y in [UInt8(y * 255 / 399), 80, 200, 255] }
        case .tiny16:
            return try TestImages.image(width: 16, height: 16) { x, y in [UInt8(x * 16), UInt8(y * 16), 128, 255] }
        case .transparent:
            return try TestImages.clear(width: 64, height: 64)
        case .sixteenBit:
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            return try Self.drawn(width: 48, height: 32, bitsPerComponent: 16, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        case .cmyk:
            return try Self.drawn(width: 48, height: 32, bitsPerComponent: 8, space: CGColorSpaceCreateDeviceCMYK(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
    }

    /// A left-red, right-blue image drawn in a context of the given format.
    private static func drawn(width: Int, height: Int, bitsPerComponent: Int, space: CGColorSpace, bitmapInfo: UInt32) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: space, bitmapInfo: bitmapInfo
        ))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        context.setFillColor(try #require(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(try #require(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        try #require(image.bitsPerComponent == bitsPerComponent)
        return image
    }
}

@MainActor
private struct Harness {
    let render: BackgroundLayerRender
    let layer: AmbientGlowLayer

    init(cardImage: CGImage) throws {
        render = try BackgroundLayerRender()
        layer = try AmbientGlowLayer(
            device: render.device, canvas: AmbientGlowLayerTests.canvas,
            cardImage: cardImage, cardRect: AmbientGlowLayerTests.cardRect
        )
    }

    func render(frame index: Int) throws -> TextureReadback {
        let size = AmbientGlowLayerTests.canvas.backgroundPixelSize
        return try render.render(layer, frame: AmbientGlowLayerTests.timeline.context(forFrame: index), width: size.width, height: size.height)
    }
}
