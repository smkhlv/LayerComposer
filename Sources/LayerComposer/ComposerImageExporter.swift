import CoreGraphics
import Foundation
import Metal

/// Renders one frame of a scene to a `CGImage`: BGRA8 premultiplied sRGB, canvas-sized, the same
/// pixels the frame encoder draws for that frame.
@MainActor
public final class ComposerImageExporter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue?

    public init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()
    }

    /// Renders one frame (default: frame 0) at canvas size; the caller encodes PNG/JPEG.
    public func render(
        scene: ComposerScene, canvas: ComposerCanvas,
        frame: ComposerFrame = ComposerTimeline.tenSeconds.context(forFrame: 0)
    ) async throws -> CGImage {
        guard !Task.isCancelled else { throw LayerComposerError.cancelled }
        guard let queue else { throw LayerComposerError.metalUnavailable }
        let encoder = try ComposerFrameEncoder(device: device, canvas: canvas, scene: scene)

        let width = canvas.pixelWidth
        let height = canvas.pixelHeight
        let bytesPerRow = width * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let output = device.makeTexture(descriptor: descriptor),
              let pixels = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            throw LayerComposerError.metalUnavailable
        }
        commandBuffer.label = "LayerComposer.still"
        try encoder.encode(frame, into: commandBuffer, output: output)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LayerComposerError.metalUnavailable
        }
        blit.copy(
            from: output, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: pixels, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { commandBuffer in
                if commandBuffer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LayerComposerError.renderFailed(
                        commandBuffer.error?.localizedDescription ?? "The still failed on the GPU."
                    ))
                }
            }
            commandBuffer.commit()
        }

        let data = Data(bytes: pixels.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else {
            throw LayerComposerError.metalUnavailable
        }
        return image
    }
}
