/// Decides, on each display-link tick of the preview, whether to render and at which clip time, and
/// when the display link can stop. Pure state, no clock of its own: the caller passes tick
/// timestamps and reports when frames are committed and completed.
///
/// A looping preview (animating, animated scene) follows the clock from its first tick and keeps
/// ticking. A still (not animating, or a static scene) renders frame 0 once and then stops. Neither
/// renders while inactive (app in the background), and a paused span does not advance the clip.
struct PreviewFrameSchedule {
    enum Tick: Equatable {
        /// Encode the frame at `time` seconds into the clip (unwrapped; the timeline loops it).
        case render(time: Double)
        /// Nothing this tick (GPU busy); keep ticking.
        case skip
        /// Nothing to do until something changes; the display link can pause.
        case stop
    }

    /// The GPU may hold at most this many preview frames; past it ticks skip instead of waiting.
    let maxFramesInFlight: Int

    var isAnimating: Bool {
        didSet {
            guard isAnimating != oldValue else { return }
            // A page that stops shows frame 0 and starts from it again when it animates.
            restart()
        }
    }

    /// The scene never changes between frames: one render is enough even while animating.
    var isStatic = false {
        didSet { if isStatic != oldValue { needsStill = true } }
    }

    /// `false` while the app is in the background.
    var isActive = true {
        // The paused span must not reach the clip as one long frame.
        didSet { lastTimestamp = nil }
    }

    private(set) var framesInFlight = 0
    private var clipTime: Double = 0
    private var lastTimestamp: Double?
    private var needsStill = true

    init(isAnimating: Bool, maxFramesInFlight: Int = 2) {
        self.isAnimating = isAnimating
        self.maxFramesInFlight = maxFramesInFlight
    }

    /// `true` while ticks can still lead to a render.
    var wantsTicks: Bool {
        isActive && (isLooping || needsStill)
    }

    mutating func tick(at timestamp: Double) -> Tick {
        guard isActive else { return .stop }
        if isLooping {
            if let lastTimestamp { clipTime += max(0, timestamp - lastTimestamp) }
            lastTimestamp = timestamp
            return framesInFlight < maxFramesInFlight ? .render(time: clipTime) : .skip
        }
        guard needsStill else { return .stop }
        return framesInFlight < maxFramesInFlight ? .render(time: 0) : .skip
    }

    /// The frame from the last `.render` was committed to the GPU.
    mutating func frameCommitted() {
        framesInFlight += 1
        if !isLooping { needsStill = false }
    }

    /// A committed frame finished on the GPU.
    mutating func frameCompleted() {
        framesInFlight = max(0, framesInFlight - 1)
    }

    /// The drawable changed (resize, new scene): a still must be rendered again.
    mutating func redraw() {
        needsStill = true
    }

    /// A new appearance: back to frame 0. Frames still in flight stay counted.
    mutating func restart() {
        clipTime = 0
        lastTimestamp = nil
        needsStill = true
    }

    private var isLooping: Bool {
        isAnimating && !isStatic
    }
}
