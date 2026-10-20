# Architecture and delivery plan

## Boundaries

`InteractionState` owns presentation, pinning, dragging and editing. `AppModel` coordinates that state, queue, clock and services. `WindowManager` owns AppKit, display selection, focus and system lifecycle. SwiftUI views own presentation. SwiftData stores note, to-do and shelf records. A JSON queue and UserDefaults deadline preserve activity and timer state. The JSON file spool is the sole external event input.

The app is directly distributed and not sandboxed. Security-scoped bookmarks preserve file references, but do not provide sandbox isolation. There is no server, account or required network connection. A future sandboxed distribution needs a separate entitlement/access design.

## UX decisions

- A selected monitor owns the workspace; disconnection falls back to a notched display or main display.
- The notch header reserves the physical cutout. Controls appear to either side or below it.
- The panel frame follows the visible surface instead of occupying a permanent invisible full-screen rectangle.
- Spring content transitions and short AppKit frame transitions are provisional; velocity-continuous panel morphing needs hardware tuning.
- Editing, dragging and pinning prevent pointer-leave collapse. Escape is an explicit override.
- Incoming tasks append while open. Current rows remain stable. Detail selection does not switch due to new events.
- Hover alone does not reveal a full dashboard. Automatic previews expire after five seconds unless interacting.
- Quiet suppresses previews, Privacy conceals content. Neither pretends to detect every screen-sharing app.
- Camera and media stop outside their visible tools; capture stops on collapse, sleep and lock. No permanent Metal display link runs.

## Rendering

Balanced uses `NSVisualEffectView`. SwiftUI shader layer effects do not capture arbitrary windows behind an overlay; Ultra therefore uses a ScreenCaptureKit display filter that excludes this app and captures a cropped top-center region. An `MTKView` samples that image with a rounded-rectangle SDF normal, edge refraction, chromatic dispersion and Fresnel/specular terms.

The current renderer is a single lens. Multi-shape smooth unions, pointer-responsive glare, efficient zero-copy pixel-buffer textures and calibrated screen color management are planned refinements, not current claims. The reference shader has a nominal 600-point crop; unusually small screens and capture geometry need verification. Capture is capped at 10 fps independently of UI motion. This is not a claim of any measured power or FPS result.

## Milestones

1. **Platform validation:** run the generated project; fix any SDK/type-check issues; verify display math, focus, first click, drag, Spaces and fullscreen. Capture a baseline with Instruments.
2. **Daily-use quality:** shelf bookmark/access recovery and outbound drag, note save failures, timer wake/relaunch, permission revocation, history usability. Add targeted integration tests for findings.
3. **Developer experience:** validate actual Claude hooks and command builds; add typed adapter protocol and per-source controls; configure real deep links; add UserPromptSubmit lifecycle if required.
4. **Rendering polish:** benchmark Balanced first; tune spring interruption; add pointer glare and smooth shape union; replace CGImage uploads with CVMetalTextureCache; test HDR/mixed-scale displays.
5. **Product depth:** configurable workspace presets, explicit clipboard/text/link shelf with retention, meeting links, local service probes, notes undo and multi-note navigation, rich media artwork/provider abstraction.
6. **Distribution:** choose bundle/signing identity, notarize, build signed release packaging, add Sparkle with owned feed/keys, validate upgrade/schema migration, then consider licensing.

No release is gated only on “the code exists.” Each milestone exits with its relevant Mac checks and measured evidence. Avoid a public plugin marketplace until the local adapter contract and attention model have survived daily use.

## API references

- https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea
- https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea
- https://developer.apple.com/documentation/appkit/nspanel
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)
- https://developer.apple.com/documentation/swiftui/view/layereffect(_:maxsampleoffset:isenabled:)

Consult the current SDK for availability. Sources were checked while implementing; that is not a substitute for compilation.
