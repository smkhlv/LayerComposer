import AVFoundation
import CoreGraphics
import CoreMedia
import Metal
import Testing
import LayerComposer

/// `ComposerVideoExporter`: a readable H.264 `.mp4` with every frame, monotonic progress, clean
/// cancellation, and a static background rendered once.
@MainActor
@Suite struct ComposerVideoExporterTests {
    static let canvas = ComposerCanvas(pixelWidth: 270, pixelHeight: 480, pointWidth: 90, pointHeight: 160, backgroundScale: 0.5)
    static let timeline = ComposerTimeline(framesPerSecond: 30, duration: 1)

    @Test func exportsReadableH264() async throws {
        let export = try await Export(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true))
        defer { export.removeFile() }

        let asset = AVURLAsset(url: export.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let (naturalSize, formats) = try await track.load(.naturalSize, .formatDescriptions)
        #expect(naturalSize == CGSize(width: 270, height: 480))
        let format = try #require(formats.first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) <= 1.0 / 30 + 1e-6)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func writesEveryFrame() async throws {
        let export = try await Export(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true))
        defer { export.removeFile() }

        let frames = try await DecodedFrames(url: export.url)

        #expect(frames.count == 30)
        #expect(frames.presentationTimes == (0..<30).map { Self.timeline.presentationTime(ofFrame: $0) })
    }

    @Test func firstFrameKeepsColorsAndOrientation() async throws {
        let foreground = try TestImages.image(width: 270, height: 480) { _, y in
            y < 240 ? [0, 0, 255, 255] : .zero
        }
        let export = try await Export(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true), foreground: foreground)
        defer { export.removeFile() }

        let first = try #require(try await DecodedFrames(url: export.url).first)

        #expect(first.pixel(x: 135, y: 60, matches: [0, 0, 255], tolerance: 16))
        #expect(first.pixel(x: 135, y: 420, matches: [0, 255, 0], tolerance: 16))
    }

    @Test func progressReachesOne() async throws {
        var values: [Double] = []
        let export = try await Export(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true)) { values.append($0) }
        defer { export.removeFile() }

        #expect(values.count >= 2)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.first.map { $0 >= 0 } == true)
        #expect(values.last == 1)
        #expect(values.dropLast().allSatisfy { $0 < 1 })
    }

    @Test func cancelledExportLeavesNoFile() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = Export.temporaryURL()
        let scene = try Export.scene(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true))
        let exporter = ComposerVideoExporter(device: device)

        let task = Task {
            try await exporter.export(scene: scene, canvas: Self.canvas, timeline: Self.timeline, to: url) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: LayerComposerError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func overwritesExistingFile() async throws {
        let url = Export.temporaryURL()
        try Data("stale".utf8).write(to: url)

        let export = try await Export(background: SolidBackground(color: [0, 1, 0, 1], isAnimated: true), url: url)
        defer { export.removeFile() }

        #expect(try await DecodedFrames(url: url).count == 30)
    }

    @Test func staticSceneExportsFast() async throws {
        let background = SolidBackground(color: [0, 1, 0, 1], isAnimated: false)
        let blur = IdentityBlur()

        let export = try await Export(background: background, blur: blur)
        defer { export.removeFile() }

        #expect(background.encodeCount == 1)
        #expect(blur.encodeCount == 1)
        #expect(try await DecodedFrames(url: export.url).count == 30)
    }
}

/// One finished export of a solid-background scene to a temporary `.mp4`.
@MainActor
private struct Export {
    let url: URL

    init(
        background: any BackgroundLayer,
        blur: any BlurStage = IdentityBlur(),
        foreground: CGImage? = nil,
        url: URL = Export.temporaryURL(),
        progress: @MainActor (Double) -> Void = { _ in }
    ) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        self.url = url
        let scene = try Self.scene(background: background, blur: blur, foreground: foreground)
        try await ComposerVideoExporter(device: device).export(
            scene: scene, canvas: ComposerVideoExporterTests.canvas, timeline: ComposerVideoExporterTests.timeline,
            to: url, progress: progress
        )
    }

    static func scene(background: any BackgroundLayer, blur: any BlurStage = IdentityBlur(), foreground: CGImage? = nil) throws -> ComposerScene {
        let canvas = ComposerVideoExporterTests.canvas
        return ComposerScene(
            background: background, blur: blur, baseColor: [1, 0, 0, 1],
            foreground: try foreground ?? TestImages.clear(width: canvas.pixelWidth, height: canvas.pixelHeight)
        )
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LayerComposerTests-\(UUID().uuidString).mp4")
    }

    func removeFile() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Every video sample of a file, decoded to BGRA.
private struct DecodedFrames {
    struct Frame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: [UInt8]

        /// True when (r, g, b) at a top-left-origin pixel is within `tolerance` of `expected`.
        func pixel(x: Int, y: Int, matches expected: SIMD3<UInt8>, tolerance: Int) -> Bool {
            let offset = y * bytesPerRow + x * 4
            let actual = SIMD3(pixels[offset + 2], pixels[offset + 1], pixels[offset])
            return (0..<3).allSatisfy { abs(Int(actual[$0]) - Int(expected[$0])) <= tolerance }
        }
    }

    private(set) var presentationTimes: [CMTime] = []
    private(set) var first: Frame?
    var count: Int { presentationTimes.count }

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        try #require(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            presentationTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
            if first == nil, let image = CMSampleBufferGetImageBuffer(sample) {
                first = Self.frame(image)
            }
        }
        #expect(reader.status == .completed)
    }

    private static func frame(_ buffer: CVPixelBuffer) -> Frame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return Frame(
            width: CVPixelBufferGetWidth(buffer), height: height, bytesPerRow: bytesPerRow,
            pixels: Array(UnsafeBufferPointer(start: base, count: bytesPerRow * height))
        )
    }
}
