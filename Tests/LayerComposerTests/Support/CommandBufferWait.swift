import Metal

extension MTLCommandBuffer {
    /// Commits and blocks until the GPU finishes: synchronous, so async tests can call it too.
    func commitAndWait() {
        commit()
        waitUntilCompleted()
    }
}
