import CoreGraphics
import SwiftUI
import Testing
import LayerComposer

/// `ForegroundRasterizer`: a SwiftUI view laid out in the canvas's points, rasterised at its pixel
/// size over a transparent background.
@MainActor
@Suite struct ForegroundRasterizerTests {
    @Test func rasterizedSizeIsCanvasPixels() throws {
        let image = try ForegroundRasterizer().rasterize(Text("Suretare"), canvas: .portrait1080p)

        #expect(image.width == 1080)
        #expect(image.height == 1920)
    }

    @Test func backgroundIsTransparent() throws {
        let image = try ForegroundRasterizer().rasterize(Text("Suretare"), canvas: .portrait1080p)
        let pixels = try RasterizedPixels(image)

        #expect(pixels.rgba(x: 0, y: 0) == .zero)
        #expect(pixels.rgba(x: 1079, y: 1919) == .zero)
    }

    @Test func contentIsDrawn() throws {
        let content = Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0)).frame(width: 100, height: 100)

        let image = try ForegroundRasterizer().rasterize(content, canvas: .portrait1080p)
        let pixels = try RasterizedPixels(image)

        #expect(pixels.pixel(x: 540, y: 960, matches: [255, 0, 0, 255]))
        // 100 pt at @3x is 300 px, centred: 390..<690 × 810..<1110.
        #expect(pixels.pixel(x: 392, y: 812, matches: [255, 0, 0, 255]))
        #expect(pixels.rgba(x: 386, y: 960) == .zero)
    }

    @Test func contentIsUpright() throws {
        let content = VStack(spacing: 0) {
            Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0)).frame(height: 10)
            Spacer(minLength: 0)
        }

        let image = try ForegroundRasterizer().rasterize(content, canvas: .portrait1080p)
        let pixels = try RasterizedPixels(image)

        #expect(pixels.pixel(x: 540, y: 5, matches: [255, 0, 0, 255]))
        #expect(pixels.rgba(x: 540, y: 1914) == .zero)
    }
}

/// RGBA8 pixels of a `CGImage`, redrawn through an sRGB premultiplied context, top-left origin.
private struct RasterizedPixels {
    let width: Int
    let pixels: [UInt8]

    init(_ image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        pixels = bytes
    }

    func rgba(x: Int, y: Int) -> SIMD4<UInt8> {
        let offset = (y * width + x) * 4
        return SIMD4(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    func pixel(x: Int, y: Int, matches expected: SIMD4<UInt8>, tolerance: Int = 2) -> Bool {
        let actual = rgba(x: x, y: y)
        return (0..<4).allSatisfy { abs(Int(actual[$0]) - Int(expected[$0])) <= tolerance }
    }
}
