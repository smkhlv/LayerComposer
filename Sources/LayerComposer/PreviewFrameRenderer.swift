import CoreGraphics
import Metal

/// One preview frame: the scene composited by `ComposerFrameEncoder` into a canvas-size texture —
/// the very pixels the exporters write — then drawn aspect-fit into a drawable of any size, the
/// rest cleared to transparent. Every texture is allocated in `init`.
@MainActor
final class PreviewFrameRenderer {
    let canvas: ComposerCanvas
    var isStatic: Bool { frameEncoder.isStatic }

    private let frameEncoder: ComposerFrameEncoder
    private let pipeline: MTLRenderPipelineState
    private let canvasTexture: MTLTexture
    private let pass: MTLRenderPassDescriptor

    init(device: MTLDevice, canvas: ComposerCanvas, scene: ComposerScene) throws {
        self.canvas = canvas
        frameEncoder = try ComposerFrameEncoder(device: device, canvas: canvas, scene: scene)
        pipeline = try Self.makePipeline(device: device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: canvas.pixelWidth, height: canvas.pixelHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let canvasTexture = device.makeTexture(descriptor: descriptor) else {
            throw LayerComposerError.metalUnavailable
        }
        self.canvasTexture = canvasTexture

        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
    }

    /// Encodes `frame` into `drawable` (`.bgra8Unorm`, render target). The caller commits.
    func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, drawable: MTLTexture) throws {
        try frameEncoder.encode(frame, into: commandBuffer, output: canvasTexture)

        pass.colorAttachments[0].texture = drawable
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LayerComposerError.metalUnavailable
        }
        encoder.label = "LayerComposer.preview"
        let fit = Self.aspectFit(width: canvas.pixelWidth, height: canvas.pixelHeight, into: drawable)
        encoder.setViewport(MTLViewport(
            originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1
        ))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(canvasTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The largest `width`×`height`-shaped rect centred in `target`, in pixels, top-left origin.
    private static func aspectFit(width: Int, height: Int, into target: MTLTexture) -> CGRect {
        let targetWidth = Double(target.width)
        let targetHeight = Double(target.height)
        let scale = min(targetWidth / Double(width), targetHeight / Double(height))
        let fitWidth = Double(width) * scale
        let fitHeight = Double(height) * scale
        return CGRect(
            x: (targetWidth - fitWidth) / 2, y: (targetHeight - fitHeight) / 2,
            width: fitWidth, height: fitHeight
        )
    }

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let vertex = library.makeFunction(name: "previewVertex"),
              let fragment = library.makeFunction(name: "previewFragment")
        else {
            throw LayerComposerError.metalUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "LayerComposer.preview"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw LayerComposerError.metalUnavailable
        }
    }
}
