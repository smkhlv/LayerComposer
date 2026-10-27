import Metal

/// Blurs the background. Both textures are `.bgra8Unorm`, premultiplied, the same size, and usable
/// as render targets and shader read/write textures.
@MainActor
public protocol BlurStage: AnyObject {
    /// Encodes the blur of `source` into `destination`, writing every pixel. The caller commits.
    func encode(source: MTLTexture, destination: MTLTexture, into commandBuffer: MTLCommandBuffer) throws
}
