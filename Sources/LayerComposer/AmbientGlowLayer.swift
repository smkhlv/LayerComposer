import CoreGraphics
import Metal

/// Tuning of `AmbientGlowLayer`. Distances are canvas pixels.
public struct AmbientGlowParameters: Sendable, Equatable {
    /// Brightness falls off as `exp(−d / falloff)` with the distance `d` from the card.
    public var falloff: Float
    /// Peak rotation of the sampled colours around the card centre, radians: `amplitude·sin φ`.
    public var rotationAmplitude: Float
    /// Brightness breathes as `1 + amplitude·sin(φ + π/2)`.
    public var breathingAmplitude: Float
    /// Side of the square colour field the card image is reduced to.
    public var fieldSize: Int

    public init(falloff: Float = 420, rotationAmplitude: Float = 0.06, breathingAmplitude: Float = 0.12, fieldSize: Int = 32) {
        self.falloff = falloff
        self.rotationAmplitude = rotationAmplitude
        self.breathingAmplitude = breathingAmplitude
        self.fieldSize = fieldSize
    }
}

/// A "TV backlight" behind the card: every pixel takes the colour of the card's nearest edge
/// (the card's own colours extruded outwards, not one flat dominant colour), fading with distance
/// and slowly turning and breathing over one seamless loop. Alpha is the falloff weight, so far
/// from the card the scene's base colour shows through.
@MainActor
public final class AmbientGlowLayer: BackgroundLayer {
    public let isAnimated = true

    private let parameters: AmbientGlowParameters
    private let canvas: ComposerCanvas
    private let cardRect: CGRect
    private let field: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let pass: MTLRenderPassDescriptor

    /// - Parameters:
    ///   - cardImage: the image as the card shows it inside `cardRect`; reduced once to the colour field.
    ///   - cardRect: the card in canvas pixels, top-left origin.
    public init(device: MTLDevice, canvas: ComposerCanvas, cardImage: CGImage, cardRect: CGRect,
                parameters: AmbientGlowParameters = AmbientGlowParameters()) throws {
        self.parameters = parameters
        self.canvas = canvas
        self.cardRect = cardRect.standardized
        let side = max(1, parameters.fieldSize)
        field = try LayerResources.texture(device: device, image: cardImage, width: side, height: side)
        pipeline = try LayerResources.pipeline(
            device: device, label: "LayerComposer.ambientGlow",
            vertex: "ambientGlowVertex", fragment: "ambientGlowFragment"
        )
        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    public func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        var uniforms = uniforms(for: frame, target: target)

        pass.colorAttachments[0].texture = target
        defer { pass.colorAttachments[0].texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw LayerComposerError.metalUnavailable
        }
        encoder.label = "LayerComposer.ambientGlow"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(field, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AmbientGlowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func uniforms(for frame: ComposerFrame, target: MTLTexture) -> AmbientGlowUniforms {
        let phase = frame.loopPhase
        let angle = parameters.rotationAmplitude * sin(phase)
        let origin = SIMD2<Float>(Float(cardRect.minX), Float(cardRect.minY))
        // A degenerate card still yields finite UVs.
        let size = SIMD2<Float>(max(1, Float(cardRect.width)), max(1, Float(cardRect.height)))
        return AmbientGlowUniforms(
            // The target is usually half resolution; distances and the card rect stay in canvas pixels.
            canvasPerTarget: SIMD2(Float(canvas.pixelWidth) / Float(target.width), Float(canvas.pixelHeight) / Float(target.height)),
            cardOrigin: origin,
            cardSize: size,
            cardCentre: origin + size / 2,
            rotation: SIMD2(cos(angle), sin(angle)),
            inverseFalloff: 1 / max(parameters.falloff, .ulpOfOne),
            brightness: 1 + parameters.breathingAmplitude * sin(phase + .pi / 2)
        )
    }
}

/// Mirrors `AmbientGlowUniforms` in `AmbientGlow.metal`.
private struct AmbientGlowUniforms {
    var canvasPerTarget: SIMD2<Float>
    var cardOrigin: SIMD2<Float>
    var cardSize: SIMD2<Float>
    var cardCentre: SIMD2<Float>
    /// (cos, sin) of the sampling rotation.
    var rotation: SIMD2<Float>
    var inverseFalloff: Float
    var brightness: Float
}
