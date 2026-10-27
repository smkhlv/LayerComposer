import CoreGraphics

/// The output frame: its pixel size, the point size layouts are made in, and how much smaller the
/// background is rendered before it is blurred and scaled up.
public struct ComposerCanvas: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pointWidth: Double
    public let pointHeight: Double
    /// Background and blur resolution relative to the canvas. After a heavy blur half resolution is
    /// indistinguishable from full and costs about a quarter.
    public let backgroundScale: Double

    public init(pixelWidth: Int, pixelHeight: Int, pointWidth: Double, pointHeight: Double, backgroundScale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backgroundScale = backgroundScale
    }

    /// 1080×1920 px, 360×640 pt at @3x, background at 540×960.
    public static let portrait1080p = ComposerCanvas(
        pixelWidth: 1080, pixelHeight: 1920, pointWidth: 360, pointHeight: 640, backgroundScale: 0.5
    )

    /// Size of the background and blur textures, at least 1×1.
    public var backgroundPixelSize: (width: Int, height: Int) {
        (
            max(1, Int((Double(pixelWidth) * backgroundScale).rounded())),
            max(1, Int((Double(pixelHeight) * backgroundScale).rounded()))
        )
    }

    public var pointSize: CGSize {
        CGSize(width: pointWidth, height: pointHeight)
    }

    /// Pixels per point.
    public var displayScale: Double {
        Double(pixelWidth) / pointWidth
    }
}
