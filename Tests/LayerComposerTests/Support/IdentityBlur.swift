import Metal
import LayerComposer

/// Copies source to destination unchanged and counts its encodes.
@MainActor
final class IdentityBlur: BlurStage {
    private(set) var encodeCount = 0

    func encode(source: MTLTexture, destination: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        encodeCount += 1
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
    }
}
