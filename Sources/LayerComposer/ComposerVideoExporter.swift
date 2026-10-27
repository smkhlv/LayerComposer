import AVFoundation
import CoreVideo
import Metal
import Synchronization

/// Renders a scene's timeline into an H.264 `.mp4`. Frames are drawn straight into the writer's
/// IOSurface-backed pixel buffers through `CVMetalTextureCache` (no copies), up to
/// `maxFramesInFlight` at once, and appended in order as their command buffers complete. The main
/// actor is never blocked: every wait is a suspension.
@MainActor
public final class ComposerVideoExporter {
    private let device: MTLDevice
    private let settings: ComposerVideoSettings
    private let queue: MTLCommandQueue?

    public init(device: MTLDevice, settings: ComposerVideoSettings = ComposerVideoSettings()) {
        self.device = device
        self.settings = settings
        queue = device.makeCommandQueue()
    }

    /// Writes canvas-size H.264 .mp4 to `url` (overwrites). Throws LayerComposerError.cancelled on
    /// task cancellation and removes the partial file. `progress` rises monotonically and reaches
    /// 1 once the file is complete.
    public func export(
        scene: ComposerScene, canvas: ComposerCanvas, timeline: ComposerTimeline,
        to url: URL, progress: @MainActor (Double) -> Void
    ) async throws {
        guard !Task.isCancelled else { throw LayerComposerError.cancelled }
        guard let queue else { throw LayerComposerError.metalUnavailable }
        try? FileManager.default.removeItem(at: url)

        let encoder = try ComposerFrameEncoder(device: device, canvas: canvas, scene: scene)
        let session = try ExportSession(
            device: device, queue: queue, encoder: encoder, timeline: timeline, settings: settings, url: url
        )
        do {
            try await session.run(progress: progress)
        } catch {
            session.abandon()
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled {
                throw LayerComposerError.cancelled
            }
            throw error
        }
    }
}

/// One export: the writer, its pixel-buffer pool and the frames on the GPU.
@MainActor
private final class ExportSession {
    private let queue: MTLCommandQueue
    private let encoder: ComposerFrameEncoder
    private let timeline: ComposerTimeline
    private let maxFramesInFlight: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let textureCache: CVMetalTextureCache

    /// Rendering or rendered, not yet appended, oldest first.
    private var inFlight: [(index: Int, target: FrameTarget)] = []

    init(
        device: MTLDevice, queue: MTLCommandQueue, encoder: ComposerFrameEncoder, timeline: ComposerTimeline,
        settings: ComposerVideoSettings, url: URL
    ) throws {
        self.queue = queue
        self.encoder = encoder
        self.timeline = timeline
        maxFramesInFlight = max(1, settings.maxFramesInFlight)
        let canvas = encoder.canvas

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw LayerComposerError.writerFailed(error.localizedDescription)
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.pixelWidth,
            AVVideoHeightKey: canvas.pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: timeline.framesPerSecond,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw LayerComposerError.writerFailed("The writer rejected the video input.")
        }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.pixelWidth,
            kCVPixelBufferHeightKey as String: canvas.pixelHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

        var cache: CVMetalTextureCache?
        let textureAttributes = [
            kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue,
        ] as CFDictionary
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, textureAttributes, &cache) == kCVReturnSuccess,
              let cache
        else {
            throw LayerComposerError.metalUnavailable
        }
        textureCache = cache
    }

    func run(progress: @MainActor (Double) -> Void) async throws {
        guard writer.startWriting() else { throw writerError() }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw writerError() }

        let frameCount = timeline.frameCount
        // The last step is finishing the file, so frames alone never report 1.
        let steps = Double(frameCount + 1)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            if inFlight.count == maxFramesInFlight {
                let appended = try await appendOldest()
                progress(Double(appended + 1) / steps)
            }
            try render(frame: index, pool: pool)
        }
        while !inFlight.isEmpty {
            let appended = try await appendOldest()
            progress(Double(appended + 1) / steps)
        }

        try Task.checkCancellation()
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerError() }
        CVMetalTextureCacheFlush(textureCache, 0)
        progress(1)
    }

    /// Stops the writer after a failure or cancellation. Frames still on the GPU keep their pixel
    /// buffers alive until their command buffers complete.
    func abandon() {
        inFlight.removeAll()
        if writer.status == .writing {
            writer.cancelWriting()
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Encodes frame `index` into a pixel buffer from the writer's pool and commits it.
    private func render(frame index: Int, pool: CVPixelBufferPool) throws {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            throw LayerComposerError.writerFailed("No pixel buffer for frame \(index).")
        }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
              ) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            throw LayerComposerError.metalUnavailable
        }
        commandBuffer.label = "LayerComposer.export.frame\(index)"
        try encoder.encode(timeline.context(forFrame: index), into: commandBuffer, output: texture)

        // The handler owns the target until the GPU is done with it, even if the export is gone.
        let target = FrameTarget(pixelBuffer: pixelBuffer, texture: cvTexture)
        commandBuffer.addCompletedHandler { commandBuffer in
            target.completion.finish(
                failure: commandBuffer.status == .completed
                    ? nil
                    : commandBuffer.error?.localizedDescription ?? "Frame \(index) failed on the GPU."
            )
        }
        commandBuffer.commit()
        inFlight.append((index, target))
    }

    /// Waits for the oldest frame's command buffer and for the writer, appends the frame and
    /// returns its index.
    private func appendOldest() async throws -> Int {
        let (index, target) = inFlight.removeFirst()
        if let failure = await target.completion.wait() {
            throw LayerComposerError.renderFailed(failure)
        }
        try Task.checkCancellation()
        // A short suspending poll: it also notices a writer that fails while not ready, and the
        // wait is bounded by the H.264 encoder, not by the poll interval (measured).
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writerError() }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(target.pixelBuffer, withPresentationTime: timeline.presentationTime(ofFrame: index)) else {
            throw writerError()
        }
        return index
    }

    private func writerError() -> LayerComposerError {
        .writerFailed(writer.error?.localizedDescription ?? "The writer stopped (status \(writer.status.rawValue)).")
    }
}

/// A frame's pixel buffer, its Metal view and its command buffer's completion. The completion
/// handler retains it and only signals `completion`; the pixel buffer is appended on the main actor
/// after that signal.
private final class FrameTarget: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let texture: CVMetalTexture
    let completion = FrameCompletion()

    init(pixelBuffer: CVPixelBuffer, texture: CVMetalTexture) {
        self.pixelBuffer = pixelBuffer
        self.texture = texture
    }
}

/// One command buffer's outcome, signalled from its completion handler and awaited on the main actor.
private final class FrameCompletion: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<String?, Never>)
        /// `nil` when the command buffer completed, else why it failed.
        case finished(String?)
    }

    private let state = Mutex(State.pending)

    func finish(failure: String?) {
        let waiter = state.withLock { state -> CheckedContinuation<String?, Never>? in
            defer { state = .finished(failure) }
            if case .waiting(let continuation) = state { return continuation }
            return nil
        }
        waiter?.resume(returning: failure)
    }

    /// The failure, or `nil` once the command buffer completed. A GPU frame takes milliseconds, so
    /// this does not respond to cancellation; the caller checks afterwards.
    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            let outcome = state.withLock { state -> String?? in
                if case .finished(let failure) = state { return .some(failure) }
                state = .waiting(continuation)
                return nil
            }
            if let outcome {
                continuation.resume(returning: outcome)
            }
        }
    }
}
