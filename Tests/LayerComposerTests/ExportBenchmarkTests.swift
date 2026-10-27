import CoreGraphics
import Foundation
import Metal
import XCTest
import LayerComposer

/// The package's own export cost at full size: 300 frames of 1080×1920 through the frame encoder
/// and the H.264 writer, and one still. Skipped unless `COMPOSER_BENCH=1`. The blur is a copy, so
/// this measures LayerComposer itself; the app's variants (spheres, Kawase blur) are benchmarked
/// on the device by the app's `StoryExportBenchmarkTests`. Results: `Benchmarks/`.
final class ExportBenchmarkTests: XCTestCase {
    static let canvas = ComposerCanvas.portrait1080p
    static let timeline = ComposerTimeline.tenSeconds
    /// A 252×336 pt card, centred, in canvas pixels.
    static let cardRect = CGRect(x: 162, y: 456, width: 756, height: 1008)

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["COMPOSER_BENCH"] == "1",
            "Set COMPOSER_BENCH=1 to run the LayerComposer export benchmark"
        )
    }

    /// Animated background: every frame renders the glow, blurs it and composites.
    @MainActor
    func testAmbientVideoExport() throws {
        try measureVideoExport(label: "ambient-video") { device in
            try AmbientGlowLayer(
                device: device, canvas: Self.canvas, cardImage: Self.cardImage(), cardRect: Self.cardRect
            )
        }
    }

    /// Static background: rendered and blurred once, then only the compositor and the writer.
    @MainActor
    func testStaticImageVideoExport() throws {
        try measureVideoExport(label: "static-video") { device in
            try ImageBackgroundLayer(device: device, image: Self.cardImage())
        }
    }

    /// One frame to a `CGImage`, as the ambient photo variant exports.
    @MainActor
    func testAmbientStillExport() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let exporter = ComposerImageExporter(device: device)
        let foreground = try Self.foreground()
        var seconds: [Double] = []

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: Self.options) {
            let done = expectation(description: "still")
            let start = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in
                do {
                    let scene = try ComposerScene(
                        background: AmbientGlowLayer(
                            device: device, canvas: Self.canvas, cardImage: Self.cardImage(), cardRect: Self.cardRect
                        ),
                        blur: CopyBlur(), baseColor: [0.1, 0.1, 0.1, 1], foreground: foreground
                    )
                    let image = try await exporter.render(scene: scene, canvas: Self.canvas)
                    XCTAssertEqual(image.width, Self.canvas.pixelWidth)
                } catch {
                    XCTFail("still export failed: \(error)")
                }
                seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                done.fulfill()
            }
            wait(for: [done], timeout: 30)
        }
        Self.report("ambient-still", device: device, seconds: seconds)
    }

    // MARK: - Private

    static var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    /// Exports the full 10 s clip `iterationCount + 1` times (XCTest's first, unrecorded run is
    /// the warm-up) and prints every run's wall time.
    @MainActor
    private func measureVideoExport(
        label: String, background: @escaping @MainActor (MTLDevice) throws -> any BackgroundLayer
    ) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let exporter = ComposerVideoExporter(device: device)
        let foreground = try Self.foreground()
        var seconds: [Double] = []

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()], options: Self.options) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(label)-\(UUID()).mp4")
            let done = expectation(description: label)
            let start = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor in
                do {
                    let scene = ComposerScene(
                        background: try background(device), blur: CopyBlur(),
                        baseColor: [0.1, 0.1, 0.1, 1], foreground: foreground
                    )
                    try await exporter.export(
                        scene: scene, canvas: Self.canvas, timeline: Self.timeline, to: url, progress: { _ in }
                    )
                } catch {
                    XCTFail("\(label) export failed: \(error)")
                }
                seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                try? FileManager.default.removeItem(at: url)
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
        }
        Self.report(label, device: device, seconds: seconds)
    }

    static func report(_ label: String, device: MTLDevice, seconds: [Double]) {
        let runs = seconds.map { String(format: "%.3f", $0) }.joined(separator: " ")
        print("COMPOSER_BENCH \(label) device=\(device.name) frames=\(timeline.frameCount) wall s (first is warm-up): \(runs)")
    }

    /// A canvas-sized foreground: a white card on a clear canvas.
    static func foreground() throws -> CGImage {
        try image(width: canvas.pixelWidth, height: canvas.pixelHeight) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(cardRect)
        }
    }

    /// A 96×128 card picture with four colour quadrants, like the app's reduced ambient source.
    static func cardImage() throws -> CGImage {
        try image(width: 96, height: 128) { context in
            let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.3), (0.2, 0.6, 0.9), (0.9, 0.8, 0.1), (0.3, 0.8, 0.4)]
            for (index, color) in colors.enumerated() {
                context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                context.fill(CGRect(x: (index % 2) * 48, y: (index / 2) * 64, width: 48, height: 64))
            }
        }
    }

    static func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }
}

/// Copies the background unchanged: the benchmark measures the composer, not a blur.
@MainActor
private final class CopyBlur: BlurStage {
    func encode(source: MTLTexture, destination: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
    }
}
