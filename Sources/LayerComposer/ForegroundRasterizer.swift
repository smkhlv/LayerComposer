import CoreGraphics
import SwiftUI

/// Turns the static foreground — any SwiftUI view — into the canvas-size `CGImage` a
/// `ComposerScene` takes. Rasterise once per composition, not per frame.
@MainActor
public struct ForegroundRasterizer {
    public init() {}

    /// Lays `content` out centred in `canvas.pointSize` and renders it at `canvas.displayScale` over
    /// a transparent background. The image is exactly the canvas's pixel size, 8-bit sRGB
    /// premultiplied BGRA.
    public func rasterize(_ content: some View, canvas: ComposerCanvas) throws -> CGImage {
        let renderer = ImageRenderer(content: content.frame(width: canvas.pointWidth, height: canvas.pointHeight))
        renderer.proposedSize = ProposedViewSize(canvas.pointSize)

        // Drawing into a context we own pins the pixel size, whatever rounding `cgImage` would do.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: canvas.pixelWidth, height: canvas.pixelHeight, bitsPerComponent: 8,
                bytesPerRow: canvas.pixelWidth * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else {
            throw ForegroundRasterizerError.renderFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: canvas.pixelWidth, height: canvas.pixelHeight))
        context.scaleBy(x: canvas.displayScale, y: canvas.displayScale)

        var didRender = false
        renderer.render { _, draw in
            draw(context)
            didRender = true
        }
        guard didRender, let image = context.makeImage() else {
            throw ForegroundRasterizerError.renderFailed
        }
        return image
    }
}

public enum ForegroundRasterizerError: Error, Equatable {
    /// SwiftUI produced no image, or the bitmap context could not be created.
    case renderFailed
}
