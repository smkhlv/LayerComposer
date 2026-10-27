import CoreGraphics

/// The layers of one composition, back to front: base colour, blurred background, foreground.
public struct ComposerScene {
    public let background: any BackgroundLayer
    public let blur: any BlurStage
    /// Premultiplied RGBA, components `0...1` in the output's (sRGB-encoded) space. Shows wherever
    /// the blurred background is transparent.
    public let baseColor: SIMD4<Float>
    /// Exactly the canvas's pixel size, any colour space or bit depth; transparent where the
    /// background should show.
    public let foreground: CGImage

    public init(background: any BackgroundLayer, blur: any BlurStage, baseColor: SIMD4<Float>, foreground: CGImage) {
        self.background = background
        self.blur = blur
        self.baseColor = baseColor
        self.foreground = foreground
    }
}
