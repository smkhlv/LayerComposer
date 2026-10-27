#if os(macOS)
import AppKit
import Metal
import SwiftUI
import Testing
import LayerComposer

/// `ComposerPreviewView` hosted in a real window: one scene per appearance, a still renders once,
/// an animated scene keeps rendering on the display link.
@MainActor
@Suite struct ComposerPreviewViewTests {
    static let canvas = ComposerCanvas(pixelWidth: 90, pixelHeight: 160, pointWidth: 30, pointHeight: 160.0 / 3.0, backgroundScale: 0.5)

    @Test func staticSceneRendersOnce() async throws {
        let host = try Host(isAnimated: false, isAnimating: true)

        try await host.run(for: .milliseconds(500))

        #expect(host.sceneCalls == 1)
        #expect(host.background.encodeCount == 1)
    }

    @Test func notAnimatingRendersOnce() async throws {
        let host = try Host(isAnimated: true, isAnimating: false)

        try await host.run(for: .milliseconds(500))

        #expect(host.sceneCalls == 1)
        #expect(host.background.encodeCount == 1)
    }

    @Test func animatedSceneKeepsRendering() async throws {
        let host = try Host(isAnimated: true, isAnimating: true)

        // Waits for the frames rather than a fixed 500 ms: under the full parallel suite the display
        // link can deliver only one tick in that window.
        try await host.run(for: .seconds(5), until: { host.background.encodeCount > 2 })

        #expect(host.sceneCalls == 1)
        #expect(host.background.encodeCount > 2)
    }

    @Test func failingSceneRendersNothing() async throws {
        let host = try Host(isAnimated: true, isAnimating: true, sceneError: LayerComposerError.metalUnavailable)

        try await host.run(for: .milliseconds(300))

        #expect(host.sceneCalls == 1)
        #expect(host.background.encodeCount == 0)
    }

    /// The preview in an on-screen window, counting `makeScene` calls.
    @MainActor
    final class Host {
        let background: SolidBackground
        private(set) var sceneCalls = 0
        private let isAnimating: Bool
        private let sceneError: (any Error)?
        private let foreground: CGImage

        init(isAnimated: Bool, isAnimating: Bool, sceneError: (any Error)? = nil) throws {
            background = SolidBackground(color: [1, 0, 0, 1], isAnimated: isAnimated)
            self.isAnimating = isAnimating
            self.sceneError = sceneError
            foreground = try TestImages.clear(width: canvas.pixelWidth, height: canvas.pixelHeight)
        }

        /// Shows the preview for `duration`, or until `done` holds when one is given.
        func run(for duration: Duration, until done: (() -> Bool)? = nil) async throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let preview = ComposerPreviewView(device: device, canvas: canvas, timeline: .tenSeconds, isAnimating: isAnimating) { [self] in
                sceneCalls += 1
                if let sceneError { throw sceneError }
                return ComposerScene(background: background, blur: IdentityBlur(), baseColor: .zero, foreground: foreground)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 300), styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: preview.frame(width: 200, height: 300))
            window.orderFrontRegardless()
            if let done {
                let deadline = ContinuousClock.now + duration
                while !done(), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } else {
                try await Task.sleep(for: duration)
            }
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
#endif
