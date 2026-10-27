import Metal
import LayerComposer

/// Fills the background target with one premultiplied colour and counts its encodes.
@MainActor
final class SolidBackground: BackgroundLayer {
    let color: SIMD4<Float>
    let isAnimated: Bool
    private(set) var encodeCount = 0

    init(color: SIMD4<Float>, isAnimated: Bool = false) {
        self.color = color
        self.isAnimated = isAnimated
    }

    func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        encodeCount += 1
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: Double(color.w)
        )
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
