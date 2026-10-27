import Metal
import Testing
import LayerComposer

/// Encodes one frame of a background layer into a fresh target, the way the encoder hands it one
/// (`.bgra8Unorm`, private, render target + shader read/write), and reads it back.
@MainActor
struct BackgroundLayerRender {
    let device: MTLDevice
    let queue: MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
    }

    func render(_ layer: any BackgroundLayer, frame: ComposerFrame, width: Int, height: Int) throws -> TextureReadback {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))

        let commandBuffer = try #require(queue.makeCommandBuffer())
        try layer.encode(frame, into: commandBuffer, target: target)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        return try TextureReadback(target, queue: queue)
    }
}
