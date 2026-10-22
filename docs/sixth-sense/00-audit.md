# Sixth Sense, Phase 0: repository audit

Audited on `feature/sixth-sense`, branched from `main` at `fa267df` (release 0.2.0). macOS 27.0, Xcode 27.1,
Swift 6.4 toolchain (the project builds in Swift 5 language mode with targeted concurrency checking).
Every file named below was read. Baseline: `swift test` ran 110 tests, 0 failures, in 12 s.

## What NotchFlow already is

NotchFlow is not a blank slate. Much of what the Sixth Sense brief asks for already ships, and some of it
is further along than the brief assumes. The brief's own rule applies: improve what exists, don't duplicate it.

| Concern | Where | Notes |
|---|---|---|
| Pure rules | `Sources/NotchCore/*` | Foundation only, deterministic, unit-tested. Compiled into the app module too (app files don't `import NotchCore`). |
| Coordination | `AppModel.swift` (1,834 lines) | `@MainActor ObservableObject`. Every visual change goes through `AppModel.commit`, which resolves the next surface size from data before animating. |
| Interaction state | `NotchCore/Interaction.swift` | `InteractionState`: presentation, pinned, dragging, editing, awareness, portal. Passive events never take the surface from a drag or a drop's result. |
| Attention | `NotchCore/Attention.swift` | `AttentionCenter`: priority, preemption, throttling, a queue that replays when the surface is free. |
| Activities | `NotchCore/Activity*.swift`, `Features/Providers.swift` | Versioned event contract, one queue, ranking, `ActivityProvider` + `ProviderHub` with per-provider enable and status. |
| Context | `NotchCore/ContextRules.swift`, `AppModel.updateContext` | Frontmost app (activation notifications only) boosts activity categories in ranking. Never opens anything. |
| Window | `Window/WindowManager.swift` | One non-activating `NSPanel`; display selection; tracking areas; global drag/approach monitors; hot key. |
| Geometry | `NotchCore/SurfaceGeometry.swift`, `Shell/SurfaceLayout.swift` | Data-driven size contracts per state: no measuring rendered views, so no layout feedback loops. |
| Design | `Design/*` | Obsidian & Silver tokens, one notch silhouette, named springs, reveal tiers, Reduce Motion and Low Power variants. |
| QA | `Window/DebugChannel.swift` | Debug builds take scripted commands from a watched folder and can render the surface to PNG. |

## Feature inventory against the brief

| Brief | State | What exists | Gap |
|---|---|---|---|
| 3.1 Context Engine | **Partial** | Frontmost-app category boost from `NSWorkspace` notifications. | No typed event model, no privacy classification, no coalescing, no per-observer lifecycle, no inspector. |
| 3.2 Intent Engine | **Missing** | Content actions are offered per item, but nothing predicts a next step from context. | Rules, scoring, cooldowns, dismissal learning, explanations, quiet hours. |
| 3.3 Action Engine | **Partial** | `ContentAction` (31 actions), `ActionRun` (tokens, progress, cancel), `ActionOutcome`, undo of created files, `ActionEffect` labels. | No declared inputs/outputs/permissions/confirmation; no action model outside dropped content. |
| 3.4 ShapeShift renderer | **Done, keep** | One silhouette, `commit` transaction, interruptible springs, portal stages, size contracts. | Priority between glance kinds is spread across `AttentionCenter`, `captureMustWait` and `InteractionState`; there is no single written-down tier model. |
| 4 Magic Drop | **Done** | Portal (aware → attracted → open → receiving → absorbing), shelf by reference, drag out, Notch Actions for images, PDFs, text, links, media, merge. | Batch rename, archive, URL QR code. Not in this branch. |
| 5 Memory Shelf | **Partial** | Opt-in, text-only, memory-only history; password-manager and concealed-type exclusion; best-effort secret filter; retention; pins. | Classification beyond link/email/color/code; contextual actions on a copy; user-editable exclusions; semantic search. |
| 6 Intent Switch | **Partial** | Product modes (Minimal, Dynamic, Developer) are presets; context boosts ranking. | Inferred modes, pinning a mode, per-detector controls. |
| 7 Predictive actions | **Missing** | | See 3.2. |
| 8 Live activities | **Done** | One activity model with honest progress (indeterminate when unknown), grouping, stack, glance, History, Mission Complete. | |
| 9 Workspace Time Machine | **Missing** | Time Travel browses past *moments*, not app/window state. | Everything. Needs Accessibility for window frames. |
| 10 Meeting Guardian | **Partial** | Calendar join links ten minutes early; Privacy hides details. | Mic/camera state (no public cross-app API), presentation detection. |
| 11 Voice | **Missing** | | |
| 12 Device continuity | **Missing** | | |
| 13 Flow Guardian | **Partial** | Focus timer, quiet mode, attention queue that defers previews. | Session summary, deferred-count report. |
| 14 Teach My Mac | **Missing** | | |
| 15 Extensions | **Partial** | The JSON inbox spool is a documented, versioned, validated public contract for activity providers. | Context and action providers; presentation schema. |
| 17 Performance | **Measured before** | Idle 0.0–0.3 % CPU, 36–40 MB at launch; no display link at rest. | |
| 18 Privacy | **Partial** | Permissions asked only when a feature is turned on; status rows in Settings. | One place that says what each capability observes, why, where it goes, how to stop and clear it. |

## Technical debt and constraints

- **`AppModel` is large.** New subsystems should live in their own types and hand `AppModel` small, explicit
  inputs, rather than adding another thousand lines to it.
- **The Xcode project is generated** by `Scripts/generate_project.py`. Any new file under `Sources/` needs a
  regeneration, and CI fails on a stale project.
- **Not sandboxed, direct distribution.** That allows the Downloads watcher and hooks. A Mac App Store build
  would need a separate entitlement design.
- **macOS has no clipboard-change notification.** The existing service compares `changeCount` about once a
  second, and only while the feature is on. Any clipboard-driven feature has to share that one poll.
- **No public API reports Focus state** without an entitlement this app doesn't have, and none reports
  another app's microphone or camera state. Features that depend on either need an honest fallback.
- **Screen sharing can't be reliably detected.** The existing Privacy toggle is the user-controlled
  presentation mode, and its documentation already says so.

## Reusable pieces

`AttentionCenter` (preemption and queueing), `InteractionState` (drag and editing precedence), the
Screenshot Magnet flow (a transient glance that waits, presents, auto-dismisses but never from under the
pointer, and replays), `ClipboardService` filters, `ClipClassifier.looksSecret`, `ShelfService.intake` and
Notch Actions (a suggestion can hand content to them), `CalendarService`, `ProviderHub`'s
start/stop/status pattern, the Debug channel's scripted commands and PNG snapshots.

## Risks

| Risk | Mitigation |
|---|---|
| Suggestions feel like notification spam | Rules-first with a score threshold, per-rule cooldowns, dismissal backoff, an hourly cap, quiet hours, a global switch. Suggestions never preempt another glance. |
| Clipboard content leaks into logs or disk | Content-class events are never persisted, the inspector shows kinds and lengths only, learning stores rule ids and counts only. |
| A suggestion fights a drag, an editor or an alert | One written-down tier model (`SurfaceArbiter`); the person's interaction always wins; actionable alerts outrank suggestions; suggestions outrank passive news. |
| Feedback loop: an action writes the clipboard and triggers a new suggestion | NotchFlow's own pasteboard writes are marked and skipped. |
| Scope: the brief describes years of work | Ship the foundation plus one complete vertical slice (copy → suggestion → action). Document the rest with honest status. |
