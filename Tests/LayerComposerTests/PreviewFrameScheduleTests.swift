import Testing
@testable import LayerComposer

/// `PreviewFrameSchedule`: when the preview renders, at which clip time, and when its display link
/// can stop.
@Suite struct PreviewFrameScheduleTests {
    @Test func staticSceneRendersExactlyOneFrame() {
        var schedule = PreviewFrameSchedule(isAnimating: true)
        schedule.isStatic = true

        #expect(schedule.tick(at: 10) == .render(time: 0))
        schedule.frameCommitted()
        schedule.frameCompleted()

        #expect(schedule.tick(at: 10.1) == .stop)
        #expect(!schedule.wantsTicks)
    }

    @Test func notAnimatingRendersOneFrame() {
        var schedule = PreviewFrameSchedule(isAnimating: false)

        #expect(schedule.tick(at: 10) == .render(time: 0))
        schedule.frameCommitted()

        #expect(schedule.tick(at: 10.1) == .stop)
        #expect(!schedule.wantsTicks)
    }

    @Test func stillWaitsForGPUInsteadOfDroppingFrame() {
        var schedule = PreviewFrameSchedule(isAnimating: true)
        _ = schedule.tick(at: 0)
        schedule.frameCommitted()
        _ = schedule.tick(at: 0.1)
        schedule.frameCommitted()
        schedule.isAnimating = false

        #expect(schedule.tick(at: 0.2) == .skip)
        #expect(schedule.wantsTicks)
        schedule.frameCompleted()
        #expect(schedule.tick(at: 0.3) == .render(time: 0))
    }

    @Test func animatingFollowsClockFromFirstTick() {
        var schedule = PreviewFrameSchedule(isAnimating: true)

        #expect(schedule.tick(at: 100) == .render(time: 0))
        schedule.frameCommitted()
        schedule.frameCompleted()
        #expect(schedule.tick(at: 100.5) == .render(time: 0.5))
        schedule.frameCommitted()
        schedule.frameCompleted()
        #expect(schedule.tick(at: 101) == .render(time: 1))
        #expect(schedule.wantsTicks)
    }

    @Test func atMostTwoFramesInFlight() {
        var schedule = PreviewFrameSchedule(isAnimating: true)

        #expect(schedule.tick(at: 0) == .render(time: 0))
        schedule.frameCommitted()
        #expect(schedule.tick(at: 0.25) == .render(time: 0.25))
        schedule.frameCommitted()
        #expect(schedule.tick(at: 0.5) == .skip)
        schedule.frameCompleted()
        #expect(schedule.tick(at: 0.75) == .render(time: 0.75))
    }

    @Test func backgroundStopsAndResumesWithoutJump() {
        var schedule = PreviewFrameSchedule(isAnimating: true)
        _ = schedule.tick(at: 0)
        _ = schedule.tick(at: 2)

        schedule.isActive = false
        #expect(!schedule.wantsTicks)
        #expect(schedule.tick(at: 3) == .stop)

        schedule.isActive = true
        #expect(schedule.wantsTicks)
        #expect(schedule.tick(at: 60) == .render(time: 2))
        #expect(schedule.tick(at: 60.5) == .render(time: 2.5))
    }

    @Test func stoppingAnimationShowsFrameZero() {
        var schedule = PreviewFrameSchedule(isAnimating: true)
        _ = schedule.tick(at: 0)
        _ = schedule.tick(at: 2)

        schedule.isAnimating = false
        #expect(schedule.tick(at: 2.5) == .render(time: 0))
        schedule.frameCommitted()
        #expect(schedule.tick(at: 3) == .stop)

        schedule.isAnimating = true
        #expect(schedule.tick(at: 4) == .render(time: 0))
    }

    @Test func redrawRendersTheStillAgain() {
        var schedule = PreviewFrameSchedule(isAnimating: false)
        _ = schedule.tick(at: 0)
        schedule.frameCommitted()
        #expect(!schedule.wantsTicks)

        schedule.redraw()

        #expect(schedule.wantsTicks)
        #expect(schedule.tick(at: 1) == .render(time: 0))
    }

    @Test func restartBeginsAtFrameZero() {
        var schedule = PreviewFrameSchedule(isAnimating: true)
        _ = schedule.tick(at: 0)
        _ = schedule.tick(at: 4)

        schedule.restart()

        #expect(schedule.tick(at: 50) == .render(time: 0))
    }
}
