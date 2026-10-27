import CoreGraphics
import Foundation
import Metal
import Testing

/// BGRA8 pixels of a texture, copied through a shared buffer so any storage mode reads back.
struct TextureReadback: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// Blits `texture` into a shared buffer on `queue` and waits for it.
    init(_ texture: MTLTexture, queue: MTLCommandQueue) throws {
        width = texture.width
        height = texture.height
        let bytesPerRow = width * 4
        let buffer = try #require(queue.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        pixels = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }

    /// (r, g, b, a) at a top-left-origin pixel.
    func rgba(x: Int, y: Int) -> SIMD4<UInt8> {
        let offset = (y * width + x) * 4
        return SIMD4(pixels[offset + 2], pixels[offset + 1], pixels[offset], pixels[offset + 3])
    }

    /// True when every channel is within `tolerance` of `expected` (r, g, b, a in 0...255).
    func pixel(x: Int, y: Int, matches expected: SIMD4<UInt8>, tolerance: UInt8 = 1) -> Bool {
        let actual = rgba(x: x, y: y)
        return (0..<4).allSatisfy { channel in
            let difference = Int(actual[channel]) - Int(expected[channel])
            return abs(difference) <= Int(tolerance)
        }
    }
}

enum TestImages {
    /// A BGRA premultiplied sRGB image from pixels written in top-left-origin coordinates.
    static func image(width: Int, height: Int, fill: (Int, Int) -> SIMD4<UInt8>) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgba = fill(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = rgba.z
                bytes[offset + 1] = rgba.y
                bytes[offset + 2] = rgba.x
                bytes[offset + 3] = rgba.w
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    static func clear(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { _, _ in .zero }
    }
}
