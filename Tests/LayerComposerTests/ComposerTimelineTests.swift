import CoreMedia
import Testing
import LayerComposer

/// `ComposerTimeline`: frame count, loop phase and exact presentation times.
@Suite struct ComposerTimelineTests {
    @Test func frameCountIs300() {
        #expect(ComposerTimeline.tenSeconds.frameCount == 300)
        #expect(ComposerTimeline(framesPerSecond: 30, duration: 1).frameCount == 30)
    }

    @Test func phaseLoopsAtDuration() {
        let timeline = ComposerTimeline.tenSeconds

        #expect(timeline.context(atTime: 10.0).loopPhase == timeline.context(atTime: 0).loopPhase)
        #expect(timeline.context(atTime: 12.5) == timeline.context(atTime: 2.5))
        #expect(timeline.context(forFrame: 300).loopPhase == timeline.context(forFrame: 0).loopPhase)
        #expect(abs(timeline.context(atTime: 5).loopPhase - .pi) < 1e-5)
    }

    @Test func presentationTimeIsExact() {
        let timeline = ComposerTimeline.tenSeconds

        #expect(timeline.presentationTime(ofFrame: 299) == CMTime(value: 299, timescale: 30))
        #expect(timeline.presentationTime(ofFrame: 0) == .zero)
    }

    @Test func frameContextCarriesIndexTimeAndDelta() {
        let frame = ComposerTimeline.tenSeconds.context(forFrame: 45)

        #expect(frame.frameIndex == 45)
        #expect(frame.time == 1.5)
        #expect(frame.deltaTime == Float(1) / 30)
    }

    @Test func portraitCanvasIsHalfResBackground() {
        let canvas = ComposerCanvas.portrait1080p

        #expect(canvas.pixelWidth == 1080 && canvas.pixelHeight == 1920)
        #expect(canvas.backgroundPixelSize == (540, 960))
        #expect(canvas.pointSize == CGSize(width: 360, height: 640))
        #expect(canvas.displayScale == 3)
    }
}
