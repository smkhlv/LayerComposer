import CoreMedia

/// A looping clip: frame rate and duration, and the per-frame context layers animate from.
public struct ComposerTimeline: Sendable, Equatable {
    public let framesPerSecond: Int
    /// Seconds.
    public let duration: Double

    public init(framesPerSecond: Int, duration: Double) {
        self.framesPerSecond = framesPerSecond
        self.duration = duration
    }

    /// 30 fps, 10 s, 300 frames.
    public static let tenSeconds = ComposerTimeline(framesPerSecond: 30, duration: 10)

    public var frameCount: Int {
        Int((duration * Double(framesPerSecond)).rounded())
    }

    /// Context of frame `index` (export). Frame `frameCount` has the same loop phase as frame 0.
    public func context(forFrame index: Int) -> ComposerFrame {
        ComposerFrame(
            frameIndex: index,
            time: Double(index) / Double(framesPerSecond),
            loopPhase: loopPhase(at: Double(index) / Double(framesPerSecond)),
            deltaTime: frameDuration
        )
    }

    /// Context at `seconds` (preview), wrapped into `0..<duration` so a running clock loops.
    public func context(atTime seconds: Double) -> ComposerFrame {
        let wrapped = wrap(seconds)
        return ComposerFrame(
            frameIndex: min(frameCount - 1, Int((wrapped * Double(framesPerSecond)).rounded(.down))),
            time: wrapped,
            loopPhase: loopPhase(at: wrapped),
            deltaTime: frameDuration
        )
    }

    /// Exact presentation time of frame `index`: `index / framesPerSecond` with no rounding.
    public func presentationTime(ofFrame index: Int) -> CMTime {
        CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
    }

    private var frameDuration: Float {
        1 / Float(framesPerSecond)
    }

    private func wrap(_ seconds: Double) -> Double {
        let remainder = seconds.truncatingRemainder(dividingBy: duration)
        return remainder < 0 ? remainder + duration : remainder
    }

    private func loopPhase(at seconds: Double) -> Float {
        Float(2 * Double.pi * wrap(seconds) / duration)
    }
}
