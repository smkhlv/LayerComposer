/// What a layer needs to draw one frame.
public struct ComposerFrame: Sendable, Equatable {
    public let frameIndex: Int
    /// Seconds since the start of the clip.
    public let time: Double
    /// `2π·(time mod duration)/duration`: drive periodic motion from this and the clip loops seamlessly.
    public let loopPhase: Float
    /// Seconds per frame, `1/fps`, for layers that step a simulation.
    public let deltaTime: Float

    public init(frameIndex: Int, time: Double, loopPhase: Float, deltaTime: Float) {
        self.frameIndex = frameIndex
        self.time = time
        self.loopPhase = loopPhase
        self.deltaTime = deltaTime
    }
}
