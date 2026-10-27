import Metal

/// The layer behind everything, rendered at the canvas's background resolution and then blurred.
@MainActor
public protocol BackgroundLayer: AnyObject {
    /// `false` → the encoder renders and blurs it once and reuses the result for every frame.
    var isAnimated: Bool { get }

    /// Encodes `frame` into `target` (`.bgra8Unorm`, premultiplied, `canvas.backgroundPixelSize`,
    /// usable as a render target and a shader read/write texture). The layer must write every pixel;
    /// the encoder does not clear the target. The caller commits the command buffer.
    func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws
}
