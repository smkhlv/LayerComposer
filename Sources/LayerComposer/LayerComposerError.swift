public enum LayerComposerError: Error, Equatable {
    /// The Metal library, a pipeline or a texture could not be created.
    case metalUnavailable
    /// The foreground image is not exactly the canvas's pixel size.
    case foregroundSizeMismatch
    /// The output texture is not `.bgra8Unorm` at the canvas's pixel size.
    case unsupportedOutput
    case writerFailed(String)
    /// A frame's command buffer failed on the GPU.
    case renderFailed(String)
    case cancelled
}
