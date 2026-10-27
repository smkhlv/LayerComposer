/// Encoder settings for `ComposerVideoExporter`. The codec is fixed: H.264 High, BT.709, `.mp4`.
public struct ComposerVideoSettings: Sendable, Equatable {
    /// Average bit rate, bits per second.
    public var bitRate: Int = 10_000_000
    /// Frames rendered on the GPU ahead of the writer. More hides GPU latency; each one holds a
    /// canvas-sized pixel buffer.
    public var maxFramesInFlight: Int = 3

    public init(bitRate: Int = 10_000_000, maxFramesInFlight: Int = 3) {
        self.bitRate = bitRate
        self.maxFramesInFlight = maxFramesInFlight
    }
}
