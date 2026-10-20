# 00 · Current-state audit (before Liquid Workspace)

Inspected 2026-10-20 on macOS 27.0 (26A428), Xcode 27.1, Mac17,3 (Apple Silicon, notched 1710×1112 pt display, notch 208×37.5 pt). Every file under `Sources/`, `Tests/`, `Scripts/`, `Resources/` and `docs/` was read. Nothing below is inferred from files that were not opened.

## Baseline

| Check | Result |
| --- | --- |
| `xcodebuild` Debug | Succeeds. 18 unique warnings, all Swift-concurrency diagnostics in `CalendarService`, `MediaService`, `SystemServices`, `BackdropService`, `WindowManager`. |
| `swift test` (NotchCore) | 9 / 9 pass. |
| Python bridge tests | 9 / 9 pass. |
| Idle CPU (60 s `top`, collapsed, no interaction) | 0.0–0.3 %, mean ≈ 0.1 %. |
| Idle memory (`footprint`) | 36 MB physical footprint. |
| Crash history | The original zip crashed on first expansion (NSHostingView constraint-pass loop under animated `setFrame`). Fixed in an earlier pass by hosting inside a container view and, later, by never animating the window frame. |

## Architecture map

| Area | Location | Notes |
| --- | --- | --- |
| Entry | `NotchFlowApp.swift` | `App` with an empty `Settings` scene; `AppDelegate` sets `.accessory`, builds the SwiftData container, `WindowManager`, status-item menu, a hand-made Settings `NSWindow`. |
| Window | `Window/WindowManager.swift` | `NotchPanel` (borderless, non-activating, `.statusBar` level, all Spaces + fullscreen auxiliary). `TrackingHostingView` owns hover tracking, scroll-to-open and file drop. Carbon hot key ⌃⌥Space, local key monitor (Esc, ⌘1–5), global click-outside monitor, sleep/lock/screen observers. |
| Geometry | `NotchCore/Interaction.swift` `DisplayGeometry`; `Design.swift` `SurfaceMetrics` | Notch width from `auxiliaryTopLeft/RightArea`, height from `safeAreaInsets.top`; simulated notch otherwise. Three fixed sizes (collapsed, preview, expanded 560×520). |
| State machine | `NotchCore/Interaction.swift` `InteractionState` | `collapsed / preview / expanded` plus independent `pinned`, `dragging`, `editing` flags and ten events. Tested. |
| Orchestration | `AppModel.swift` | Single `ObservableObject`: presentation, `tab`, queue, countdown, a 1 Hz `now`, message, selection, attention record, geometry, all services. `send(_:)` grows the panel, runs one spring, trims the panel on completion. |
| Views | `OverlayView.swift`, `Features/FeatureViews.swift` | Root silhouette, `CompactHeader` band, preview card, workspace header + 5-tab bottom bar; Activity, Focus timer, History, Shelf, Music, Tools (segmented: Notes, To-dos, Calendar, Mirror, Quick apps), single scratch note, to-dos. |
| Design primitives | `Design.swift` | Motion presets, `NotchShape`, `materialize` / `swap` transitions, hover fills, icon/tab/row button styles, phase icon. Colors in an ad-hoc `Palette` (3 values) plus raw `.white.opacity(…)` throughout. |
| Rendering | `Graphics/GlassSurface.swift`, `BackdropService.swift`, `Resources/LiquidGlass.metal` | Performance = black; Balanced = `NSVisualEffectView` + tint; Ultra = ScreenCaptureKit 10 fps crop → `MTKView` (paused, draws on demand) with a fixed 27 pt rounded-rect SDF that does not match the notch silhouette. |
| Activity input | `Features/EventBridge.swift`, `Scripts/notchflow.py` | Owner-only JSON spool watched by a DispatchSource; validation in `ActivityEvent.validate`. |
| Persistence | SwiftData (`Note`, `Todo`, `ShelfFile`), `activities.json`, `UserDefaults` (preferences, countdown) | Shelf stores security-scoped bookmarks; originals are never moved. |
| Services | `MediaService` (AppleScript every 2 s, only while Music tab visible), `CalendarService` (EventKit), `CameraService`, `BatteryService` (60 s poll), `ShelfService`, `QuickAction` | |

## UX findings (against the Liquid Workspace brief)

1. **Fixed container.** Expanded is always 560×520 regardless of content; an empty Notes or disconnected Music shows a mostly empty panel (brief problems B, Part 4.4).
2. **Navigation layers.** A permanent 5-item bottom bar, a large title row with four header buttons, plus a segmented control inside Tools (problem C).
3. **Page replacement.** Tabs crossfade inside the same rectangle; nothing persists across a switch (problem D). Only the silhouette morph (added in the prior pass) is spatial.
4. **Notifications.** `failed` / `completed` events raise a generic preview; there is no priority, queueing, throttling, or editing-aware suppression beyond `InteractionState` refusing to replace an expanded workspace.
5. **Hover.** `mouseEntered` previews immediately; no proximity awareness, no configurable delay; exit uses a fixed 0.35 s check against the panel rectangle.
6. **Drag.** Shelf reacts only once a drag is inside the panel; there is no approach behavior, arrival feedback or auto-return.
7. **Content.** One scratch note only; to-dos cannot be edited or individually deleted; Quick Apps are three hard-coded text buttons; History is a flat list with no grouping, inline detail, clearing or retention.
8. **Materials.** Balanced is a uniform tinted blur with a gradient hairline; no material levels, no transient illumination.

## Engineering risks

- **Window resizing vs. SwiftUI layout.** The original crash proves animated frame changes on a hosting window are unsafe. Any content-driven sizing must not feed measured SwiftUI sizes back into the window during layout.
- **Whole-tree invalidation.** `now` publishes every second on `AppModel`, re-rendering the root view even when collapsed.
- **Synchronous AppleScript** on the main thread (2 s timeout) in `MediaService`.
- **Hit testing.** Transparent pixels of the panel during a grow/trim window (≈0.3–0.5 s) are inside the window bounds.
- **No UI test target.** Only NotchCore is unit-testable; app behavior needs scripted runs.

## Migration strategy

Keep the AppKit host, panel, hot key, bridge, services and SwiftData models. Replace the view layer and the presentation orchestration in buildable steps, in the brief's order: geometry → adaptive layout → motion → Activity / Notifications → Music → Tools → Shelf → remaining features → Metal. Pure logic (attention priority, size negotiation, history pruning) moves into NotchCore so it can be unit-tested. Every step builds, runs the test suites and is inspected with screen recordings before the next begins.
