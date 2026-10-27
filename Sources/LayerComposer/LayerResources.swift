import CoreGraphics
import Metal

/// Textures and pipelines the built-in background layers share.
enum LayerResources {
    /// Uploads `image` as a `.bgra8Unorm` premultiplied texture, drawn first into an 8-bit sRGB
    /// context of `width`×`height` — so any source colour space or bit depth (CMYK, 16-bit, float)
    /// works, and resizing happens in Core Graphics.
    static func texture(device: MTLDevice, image: CGImage, width: Int, height: Int) throws -> MTLTexture {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else {
            throw LayerComposerError.metalUnavailable
        }
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else {
            throw LayerComposerError.metalUnavailable
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LayerComposerError.metalUnavailable
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: context.bytesPerRow
        )
        return texture
    }

    /// The pipeline for a fullscreen-triangle pass into a `.bgra8Unorm` target.
    static func pipeline(device: MTLDevice, label: String, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment)
        else {
            throw LayerComposerError.metalUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw LayerComposerError.metalUnavailable
        }
    }
}
