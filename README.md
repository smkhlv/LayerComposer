# LayerComposer

A Swift/Metal library that glues layers into frames: an animated or static background, a blur stage
and a static foreground image, composited over a base colour. The same frame encoder drives a live
preview, a video export and a still image, so what the preview shows is what gets exported.

It has no package dependencies. Backgrounds and blurs plug in through two small protocols, so any
Metal renderer (spheres, a photo, a shader) and any blur can be used.

## Features

- **Video export**: H.264 High `.mp4`, BT.709, no audio. Frames go straight into the writer's
  IOSurface-backed pixel buffers (no copies), up to three on the GPU at once. Cancellable, with
  progress.
- **Still export**: one frame as a `CGImage`.
- **Live preview**: a SwiftUI view that loops the timeline on a display link. It renders once and
  stops when nothing moves.
- **Static backgrounds cost one render**: a background that does not move is rendered and blurred
  once and reused for every frame.
- **Half-resolution background**: background and blur run at half the canvas size by default. After
  a heavy blur this looks the same and costs about a quarter as much.
- **Built-in layers**: `ImageBackgroundLayer` (a photo, aspect-filled) and `AmbientGlowLayer` (a
  "TV backlight" built from a card's own colours).

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.0+

## Installation

```swift
dependencies: [
    .package(path: "../LayerComposer")
]
```

## Pipeline

Per frame, all on the GPU, in the caller's command buffer:

```
BackgroundLayer ──► background texture (canvas.backgroundPixelSize, half res by default)
      BlurStage ──► blurred texture (same size)          ← once, if the background is static
     Compositor ──► output (canvas size): base colour
                                          + blurred background, bilinear upscale
                                          + foreground (uploaded once)
```

All textures are `.bgra8Unorm` with premultiplied alpha. `ComposerFrameEncoder` allocates its
textures once, in `init`; encoding a frame allocates nothing.

## Building a scene

A scene is a background, a blur, a premultiplied base colour and a canvas-sized foreground image.

### Protocols

```swift
import LayerComposer
import Metal

/// Any Metal renderer can be a background.
@MainActor
final class GradientBackground: BackgroundLayer {
    let isAnimated = true   // false: rendered and blurred once, reused every frame

    func encode(_ frame: ComposerFrame, into commandBuffer: MTLCommandBuffer, target: MTLTexture) throws {
        // Draw into `target` and write every pixel. `frame.loopPhase` runs 0..<2π over the clip,
        // so motion driven by it loops seamlessly; `frame.deltaTime` is 1/fps for simulations.
    }
}

/// Any blur, or a copy for none.
@MainActor
final class MyBlur: BlurStage {
    func encode(source: MTLTexture, destination: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        // Write every pixel of `destination`. Both textures are the same size.
    }
}
```

The caller commits the command buffer in both cases. Allocate what a layer needs in its `init`,
not in `encode`: an export calls `encode` 300 times.

### Foreground

The foreground never moves, so it is rasterised once. `ForegroundRasterizer` turns any SwiftUI view
into the canvas-sized image a scene takes. Load remote images first: `ImageRenderer` cannot wait
for them.

```swift
let canvas = ComposerCanvas.portrait1080p          // 1080×1920 px, 360×640 pt, background 540×960
let foreground = try ForegroundRasterizer().rasterize(StoryOverlay(), canvas: canvas)

let scene = ComposerScene(
    background: GradientBackground(),
    blur: MyBlur(),
    baseColor: SIMD4(0, 0, 0, 1),                   // premultiplied RGBA, shows where the background is clear
    foreground: foreground                           // exactly the canvas's pixel size
)
```

### Built-in layers

```swift
// A photo, aspect-filled and centred. Static: rendered and blurred once per export.
let photo = try ImageBackgroundLayer(device: device, image: cgImage)

// The card's colours extruded outwards from its edges, fading with distance, slowly turning and
// breathing over one seamless loop. `cardImage` is the picture as the card shows it (it is reduced
// to a 32×32 colour field once); `cardRect` is the card in canvas pixels, top-left origin.
let glow = try AmbientGlowLayer(
    device: device, canvas: canvas, cardImage: cardCGImage, cardRect: cardPixelRect,
    parameters: AmbientGlowParameters()   // falloff 420 px, rotation 0.06 rad, breathing 0.12, field 32
)
```

`AmbientGlowLayer`'s alpha is its falloff weight: far from the card the scene's base colour shows
through, so a tinted base (for example the card's dominant colour at low luminance) reads as a
floor rather than flat black.

## Exporting a video

```swift
let exporter = ComposerVideoExporter(device: device)   // ComposerVideoSettings(): 10 Mbps, 3 frames in flight
try await exporter.export(
    scene: scene, canvas: canvas, timeline: .tenSeconds,   // 30 fps, 300 frames
    to: url
) { fraction in
    progressView.progress = fraction                        // rises monotonically, reaches 1 when the file is done
}
```

The exporter runs on the main actor but never blocks it: every wait is a suspension. Cancel the
calling task to stop. It then throws `LayerComposerError.cancelled` and deletes the partial file.
Frames still on the GPU keep their buffers until they finish, so nothing is freed under the GPU.

## Exporting a still

```swift
let image = try await ComposerImageExporter(device: device).render(
    scene: scene, canvas: canvas, frame: ComposerTimeline.tenSeconds.context(forFrame: 0)
)
// 1080×1920, 8-bit sRGB premultiplied BGRA. Encode JPEG or PNG as needed.
```

## Live preview

```swift
ComposerPreviewView(
    device: device, canvas: canvas, timeline: .tenSeconds,
    isAnimating: isCentredPage                // false, or a static scene: draws frame 0 once and stops
) {
    try makeScene()                            // called once per appearance, so its state starts fresh
}
.aspectRatio(9 / 16, contentMode: .fit)
```

The preview draws aspect-fit into a `CAMetalLayer` at the view's size × screen scale, with the same
encoder as the exporters. It pauses while the app is in the background. A carousel should animate
only its centred page.

## Frame encoder

The exporters and the preview are built on `ComposerFrameEncoder`, which you can drive yourself:

```swift
let encoder = try ComposerFrameEncoder(device: device, canvas: canvas, scene: scene)
let timeline = ComposerTimeline.tenSeconds
for index in 0..<timeline.frameCount {
    let commandBuffer = queue.makeCommandBuffer()!
    try encoder.encode(timeline.context(forFrame: index), into: commandBuffer, output: outputTexture)
    commandBuffer.commit()
}
```

`output` must be `.bgra8Unorm` at the canvas's pixel size and usable as a render target. Commit
every command buffer to one queue: a static background is rendered in the first frame's buffer and
read by the later ones.

## Performance

A full 300-frame 1080×1920 export is bound by the H.264 encoder, not by the composer: on an M1 Pro,
an animated and a static background both take about 1.6 s. On an iPhone 16 the Suretare story
variants (spheres and ambient glow under a Dual Kawase blur) export in about 1.85 s per video and
0.05 s per photo. The first video after launch takes about 2.8 s: the encoder's warm-up, which runs
off the main thread. Peak memory is about +100 MB per video. Details, with before and after numbers,
are in [`Benchmarks/`](Benchmarks/).

The exporters keep the main thread free while they encode. Building the `ComposerScene`, and above
all rasterising its foreground, is the caller's main-thread work: in the app, a 1080×1920 SwiftUI
foreground took 25–50 ms. Build each foreground once and reuse it for the preview and the export.

```bash
COMPOSER_BENCH=1 swift test --filter ExportBenchmark
```

## Errors

`LayerComposerError`: `metalUnavailable`, `foregroundSizeMismatch`, `unsupportedOutput`,
`writerFailed(String)`, `renderFailed(String)`, `cancelled`. `ForegroundRasterizerError.renderFailed`
when SwiftUI produces no image.

## License

MIT — see [LICENSE](LICENSE).
