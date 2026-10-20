# 04 · Rendering

The interface is complete and coherent without Metal; Ultra is an enhancement on top.

## Modes

| Mode | Surface | Capture | GPU work |
| --- | --- | --- | --- |
| Performance | Solid `Ink.void` | None | SwiftUI drawing only |
| Balanced (default) | Pure-black band → `NSVisualEffectView` (.hudWindow) + obsidian 86 % + bottom lift | None | System blur behind the panel |
| Ultra (opt-in) | Balanced + Metal refraction layer | ScreenCaptureKit, 10 fps, top-centre crop, excludes this app | One full-surface fragment pass per captured frame or shape change |

Reduce Transparency forces the solid surface and stops capture. Layout, sizes and controls are identical in every mode.

## Ultra pipeline

`BackdropService` (unchanged capture lifecycle) streams a cropped top-centre region at 10 fps only while the workspace is expanded in Ultra, and stops on collapse, sleep, lock or permission loss. Frames stay in memory. `RefractiveGlass` is an `MTKView` with `isPaused = true` / `enableSetNeedsDisplay = true`: it draws only when a new frame or a new silhouette arrives — no display link at idle. The texture is rebuilt only when the captured image changes.

`LiquidGlass.metal` now receives the live silhouette (`GlassUniforms`: size, capture size, ear, bottom radius, band) instead of a fixed 27 pt rectangle:

- signed distance to the notch body (flat top, rounded bottom corners, inset by the ears) via a per-corner rounded-box SDF;
- surface normal from the SDF gradient; refraction strongest within ~12 pt of the rim, none in the middle;
- slight chromatic dispersion (red bends 5 % more, blue 5 % less);
- Fresnel-like rim glow and a directional glint on the lower edges, faded in below the band.

Because the uniforms follow the animated form, the bending follows the silhouette while it morphs.

## Verification

- The shader compiles and its render pipeline builds through the Metal runtime compiler, the same path the app uses (`device.makeLibrary(source:)`). The offline `metal` compiler used by CI is a separate Xcode component not installed on this Mac, so the CI shader step was not run here.
- Ultra was **not** visually verified: it requires granting Screen Recording permission, which I did not do. Balanced and Performance were verified on screen.

## Not implemented (deliberately deferred)

- Smooth SDF unions for merging transient shapes into the main surface. The surface already morphs as one shape; a second shape that merges in would need a coordinated multi-shape renderer, which would add cost without a clear interaction that needs it yet.
- Zero-copy `CVMetalTextureCache` upload (frames still pass through `CGImage`), pointer-responsive glare, and calibrated colour management for HDR or mixed-scale displays.
