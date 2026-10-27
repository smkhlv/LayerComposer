import CoreGraphics
import Metal

/// Encodes one composited frame: background → blur → compositor (base colour, blurred background
/// scaled up bilinearly, foreground). Every texture is allocated in `init`; encoding a frame
/// allocates none. A static background is rendered and blurred on the first frame only — and again
/// if that frame's command buffer is dropped or fails. Commit every command buffer to one queue.
@MainActor
public final class ComposerFrameEncoder {
    public let canvas: ComposerCanvas
    /// `true` when nothing in the scene moves (static background): every frame is identical.
    public var isStatic: Bool { !background.isAnimated }

    private let background: any BackgroundLayer
    private let blur: any BlurStage
    private var baseColor: SIMD4<Float>
    private let pipeline: MTLRenderPipelineState
    private let backgroundTexture: MTLTexture
    private let blurredTexture: MTLTexture
    private let foregroundTexture: MTLTexture
    private let pass: MTLRenderPassDescriptor
    /// For a static scene: whether the blurred texture holds the background yet.
    private var staticBackground = StaticBackground.empty

    public init(device: MTLDevice, canvas: ComposerCanvas, scene: ComposerScene) throws {
        guard scene.foreground.width == canvas.pixelWidth, scene.foreground.height == canvas.pixelHeight else {
            throw LayerComposerError.foregroundSizeMismatch
        }
        self.canvas = canvas
        background = scene.background
        blur = scene.blur
        baseColor = scene.baseColor
        pipeline = try Self.makePipeline(device: device)

        let backgroundSize = canvas.backgroundPixelSize
        backgroundTexture = try Self.makeIntermediate(device: device, width: backgroundSize.width, height: backgroundSize.height)
        blurredTexture = try Self.makeIntermediate(device: device, width: backgroundSize.width, height: backgroundSize.height)
        foregroundTexture = try Self.makeForeground(device: device, image: scene.foreground)

        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    /// Encodes `frame` into `output` (`.bgra8Unorm`, canvas pixel size, render target). The caller
    /// commits the command buffer.
    public func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, output: MTLTexture) throws {
        guard output.pixelFormat == .bgra8Unorm,
              output.width == canvas.pixelWidth,
              output.height == canvas.pixelHeight
        else {
            throw LayerComposerError.unsupportedOutput
        }

        if needsBackground(in: commandBuffer) {
            staticBackground = .empty
            try background.encode(frame, into: commandBuffer, target: backgroundTexture)
            try blur.encode(source: backgroundTexture, destination: blurredTexture, into: commandBuffer)
            staticBackground = .rendering(commandBuffer)
        }

        pass.colorAttachments[0].texture = output
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LayerComposerError.metalUnavailable
        }
        encoder.label = "LayerComposer.compositor"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(blurredTexture, index: 0)
        encoder.setFragmentTexture(foregroundTexture, index: 1)
        encoder.setFragmentBytes(&baseColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Whether `commandBuffer` must render and blur the background. A static background is reused
    /// once the command buffer that rendered it is committed (the queue runs it first) and kept for
    /// good once that buffer completed; a failed buffer, or one still uncommitted when another frame
    /// is encoded (it may never run), leaves the texture empty, so this frame renders it again.
    private func needsBackground(in commandBuffer: MTLCommandBuffer) -> Bool {
        guard isStatic else { return true }
        switch staticBackground {
        case .empty:
            return true
        case .ready:
            return false
        case .rendering(let renderer):
            switch renderer.status {
            case .completed:
                staticBackground = .ready
                return false
            case .notEnqueued:
                return renderer !== commandBuffer
            case .enqueued, .committed, .scheduled:
                return false
            case .error:
                return true
            @unknown default:
                return true
            }
        }
    }

    private enum StaticBackground {
        case empty
        /// Encoded into this command buffer, which has not completed yet.
        case rendering(MTLCommandBuffer)
        case ready
    }

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let vertex = library.makeFunction(name: "compositorVertex"),
              let fragment = library.makeFunction(name: "compositorFragment")
        else {
            throw LayerComposerError.metalUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "LayerComposer.compositor"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw LayerComposerError.metalUnavailable
        }
    }

    /// Half-resolution background or blur texture, GPU-only.
    private static func makeIntermediate(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LayerComposerError.metalUnavailable
        }
        return texture
    }

    /// Draws `image` into an 8-bit sRGB premultiplied BGRA context — so any source colour space or
    /// bit depth works — and uploads it once.
    private static func makeForeground(device: MTLDevice, image: CGImage) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else {
            throw LayerComposerError.metalUnavailable
        }
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
}
