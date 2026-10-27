import CoreGraphics
import Metal

/// A static photo behind everything, aspect-filled into the target and centred. Static, so the
/// encoder renders and blurs it once per export.
@MainActor
public final class ImageBackgroundLayer: BackgroundLayer {
    public let isAnimated = false

    /// Longest side of the uploaded texture. The target is at most a few hundred pixels and blurred
    /// right after, so a larger upload only costs memory.
    static let maxTextureSide = 2048

    private let texture: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let pass: MTLRenderPassDescriptor

    public init(device: MTLDevice, image: CGImage) throws {
        let scale = min(1, Double(Self.maxTextureSide) / Double(max(image.width, image.height)))
        texture = try LayerResources.texture(
            device: device, image: image,
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
        pipeline = try LayerResources.pipeline(
            device: device, label: "LayerComposer.imageBackground",
            vertex: "imageBackgroundVertex", fragment: "imageBackgroundFragment"
        )
        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    public func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        // Aspect-fill: the image scales until it covers the target; the fraction of it that stays
        // visible along each axis is centred.
        let fill = max(Double(target.width) / Double(texture.width), Double(target.height) / Double(texture.height))
        var visible = SIMD2<Float>(
            Float(Double(target.width) / (Double(texture.width) * fill)),
            Float(Double(target.height) / (Double(texture.height) * fill))
        )

        pass.colorAttachments[0].texture = target
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LayerComposerError.metalUnavailable
        }
        encoder.label = "LayerComposer.imageBackground"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&visible, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
