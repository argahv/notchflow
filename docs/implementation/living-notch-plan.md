# Living Notch — audit and implementation plan

Branch `feat/living-notch`, from `main` at `f0f7f58`. Baseline before any change: 60 Swift tests
(`swift test`) and 23 Python tests (`python3 -m unittest discover -s Tests -p 'test_*.py'`), all passing.

## Audit

**What exists and is reused.**

| Area | Existing piece | Reused for |
|---|---|---|
| Interaction | `InteractionState` (presentation, pin, drag, edit, awareness) | Portal stages become new events and one new field on it, not a second state machine |
| Geometry | `SurfaceLayout.form` → `SurfaceGeometryEngine.resolve`; `WindowManager.prepare/settle` | Every new form (portal, capture preview, result, completion) is one more case in the same resolver |
| Motion | `Motion` presets, `Reveal` tiers, `EdgeLight`, `RimIllumination`, `NotchShape` | All new motion; no new animation controller |
| Drag in | Global `leftMouseDragged` monitor reading only the drag pasteboard's type list; `TrackingHostingView` drop handlers; `DropApproach` | Portal proximity and drop handling |
| Shelf | `ShelfService` (security-scoped bookmarks, QuickLook thumbnails in a bounded `NSCache`), `ShelfSurface`, SwiftData `ShelfFile` | Extended for text, links, owned content, metadata, Quick Look, copy, drag-out |
| Attention | `AttentionCenter` (preempt, queue, throttle, indicate) | Conflict rules: passive events never interrupt a drag or a running action |
| Hover | `HoverPolicy` (deterministic tiers, split pairing, stability) | Living Split Island extends it (pin, cycle) |
| Activities | `ActivityQueue` v2, `AgentMetadata.state/tool`, `ActivityRanking`, `ProviderHub` | Agent heartbeat, Mission Complete, Time Travel |
| Directory watching | `DownloadsProvider`, `DebugChannel` (DispatchSource on a folder) | Screenshot detection |
| Text rules | `ClipClassifier` (kind, `looksSecret`) | Content classification for actions; secret handling |
| Audio | `MediaService` (Music/Spotify), `AudioDevices` (CoreAudio outputs) | Sound Island |
| QA | `DebugChannel` commands, offscreen `snapshot` | Scripted checks for every new state |

**Overlaps (enhance, don't rebuild).** Portal ↔ drag-to-shelf. Screenshot Magnet ↔ the downloads folder
watcher. Notch Actions ↔ `ClipClassifier`. Heartbeat ↔ band activity dots and `AgentState`. Split Island
↔ `HoverPolicy` split. Time Travel ↔ History and `ActivityQueue`. Sound Island ↔ Tools › Sound and
`MediaService`. Mission Complete ↔ `AttentionCenter` informational glances.

**Where logic lives.** Pure, testable rules in `Sources/NotchCore` (compiled into the app and covered by
`swift test`); AppKit adapters in `Sources/NotchFlow/Features`; views in `Shell` and `Surfaces`.
`Scripts/generate_project.py` globs `Sources/**/*.swift`; the regenerated project is committed (CI diffs it).

**Permissions.**
- Portal, Actions, Heartbeat, Split Island, Time Travel, Mission Complete: none new. Drops are explicit.
- Screenshot Magnet: reads the folder macOS saves screenshots to (Desktop by default, which is
  TCC-protected), so it is opt-in and asks only when turned on. No Screen Recording, no key monitoring.
- OCR (Vision) runs on device and needs no permission.
- Sound Island: CoreAudio property listeners need no permission. There is no public, reliable signal
  for another app's microphone use, so no microphone indicator is built.

**APIs.** `NSDraggingDestination`, `NSFilePromiseReceiver`, `NSItemProvider`, `QLPreviewPanel`,
`QLThumbnailGenerator`, Vision `VNRecognizeTextRequest`, ImageIO, PDFKit, Core Image, CoreAudio property
listeners, `DispatchSource` file-system sources. All public on macOS 14.6 (the deployment target).

**Idle cost.** Everything is event-driven (notifications, dispatch sources, CoreAudio listeners). No timers
at rest. Continuous motion is bounded: indicators animate for a fixed time after a real state change and
then hold still.

## Plan, by phase

Each phase: build Debug and Release, run both test suites, capture states with the debug channel, commit,
record results in [living-notch-progress.md](living-notch-progress.md).

1. **Notch Portal.** `InteractionState` gains `portal` and events (aware → attracted → open → absorbing /
   failed → settled). `NotchCore/PortalRules.swift`: drag-type eligibility, content kind and count, the
   shelf intake policy (limits, dedupe keys, owned vs referenced content). `WindowManager`: staged
   proximity zones, more dragged types, file promises. `ShelfService`: text, links, owned files,
   metadata, copy, Quick Look, clear with undo, orphan cleanup. `SurfaceLayout` portal forms;
   `PortalView` (awareness affordance, target, opening, absorption); `ShelfSurface` tiles with metadata,
   actions and type-aware drag-out.
2. **Screenshot Magnet.** `ScreenshotWatcher` (opt-in folder source, screencapture location, name and
   recency filters, dedupe), capture preview form, Vision OCR service with cancellation, annotation
   editor with irreversible redaction, shelf integration.
3. **Notch Actions.** `NotchCore/ContentContext` classifier, action registry and lifecycle state machine;
   local executors (ImageIO, Core Image, Vision, PDFKit, AVFoundation); result surface in the same
   silhouette. Remote AI actions stay out unless configured and consented.
4. **Agent Heartbeat and Mission Complete.** `AgentVisualStateResolver` over existing agent records;
   bounded band motion per state; completion presentation policy (importance, batching, quiet, typing).
5. **Living Split Island.** `HoverPolicy` pin and user cycling; horizontal scroll and keyboard cycling;
   region-to-feature morph.
6. **Time Travel.** `TimelineProvider` merging History, shelf, screenshots, timers; explicit mode;
   source-exists checks for actions; retention honoured.
7. **Spatial Sound Island.** CoreAudio listeners for default output and volume; transient output
   transition; compact controls through `MediaService` and `AudioDevices`.
8. **Polish and release validation.** Cross-feature conflicts, accessibility, profiling, security review.
