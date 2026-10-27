# Changelog

## 1.0.0 — 2026-10-27

First release.

### Added

- `ComposerCanvas` (`.portrait1080p`: 1080×1920 px, 360×640 pt, background at half resolution) and
  `ComposerTimeline` (`.tenSeconds`: 30 fps, 300 frames) with per-frame `ComposerFrame` contexts,
  a seamless `loopPhase` and exact `CMTime` presentation times.
- `BackgroundLayer` and `BlurStage` protocols, and `ComposerScene` (background, blur, base colour,
  foreground image).
- `ComposerFrameEncoder`: background → blur → one compositor pass (base colour, blurred background
  scaled up bilinearly, foreground) into a caller's `.bgra8Unorm` texture. Textures are allocated
  once; a static background is rendered and blurred once and reused.
- `ImageBackgroundLayer`: a static photo, aspect-filled and centred, uploaded at most 2048 px on
  its long side.
- `AmbientGlowLayer` and `AmbientGlowParameters`: the card's colours extruded outwards from its
  nearest edge, falling off as `exp(−d/420)`, turning by `0.06·sin φ` and breathing by
  `1 + 0.12·sin(φ + π/2)` over one seamless loop. Any source image works: it is redrawn into 8-bit
  sRGB first.
- `ComposerVideoExporter` and `ComposerVideoSettings`: H.264 High `.mp4` at 10 Mbps, BT.709, no
  audio. Frames go straight into the writer's IOSurface-backed pixel buffers through
  `CVMetalTextureCache`, up to three in flight. Progress rises monotonically; cancelling the task
  throws `LayerComposerError.cancelled` and deletes the partial file.
- `ComposerImageExporter`: one frame as an 8-bit sRGB `CGImage`.
- `ComposerPreviewView`: a SwiftUI live preview with the exporters' encoder, looping on a display
  link, paused in the background; a static or non-animating scene draws once and stops.
- `ForegroundRasterizer`: any SwiftUI view to the canvas-sized foreground image.
- `LayerComposerError`, `ForegroundRasterizerError`.
- `ExportBenchmarkTests` (`COMPOSER_BENCH=1`) and `Benchmarks/2026-10-27-iphone.md` (iPhone 16 story
  exports and the macOS package benchmark).
