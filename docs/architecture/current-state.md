# Current state (start of Liquid Workspace 2.0)

Audited on branch `feat/liquid-workspace-2` from `main` @ `a228e6f`. macOS 27.0, Xcode 27.1, Claude Code 2.1.302 installed; no Codex CLI on `PATH` (`~/.codex` exists). Every file referenced below was read.

## Structure

| Concern | Where | Notes |
| --- | --- | --- |
| Entry, lifecycle, menu bar | `NotchFlowApp.swift` | `.accessory` app; `AppDelegate` builds the SwiftData container (`Note`, `Todo`, `ShelfFile`), `WindowManager`, status-item menu, a hand-built Settings window |
| Window / panel | `Window/WindowManager.swift` | One `NotchPanel` (borderless, non-activating, `.statusBar`, all Spaces + fullscreen auxiliary). Frame never animated: grows before a transition, trims after (plus a 0.9 s fallback) |
| Geometry | `NotchCore/Interaction.swift` (`DisplayGeometry`), `NotchCore/SurfaceGeometry.swift`, `Shell/SurfaceLayout.swift` | Notch from `auxiliaryTopLeft/RightArea`; data-driven size contracts resolved by a tested engine |
| Input | `WindowManager` | Tracking area (hover intent + 300 ms exit grace), passive global monitors (mouse-moved approach, left-drag approach, mouse-up, click-outside), local key monitor (Esc, ⌘1–5, ⌘K, ↑/↓), Carbon hot key ⌃⌥Space |
| State | `NotchCore/Interaction.swift`, `Shell/Route.swift`, `AppModel.swift` | `InteractionState` (presentation + pinned/dragging/editing/awareness) + `Route` + open note = `PresentationSnapshot`; `AppModel.commit` is the single animated path |
| Views | `Shell/OverlayView.swift`, `Surfaces/*` | Silhouette root, band (status or dock), glance, workspace; Activity, Music, Shelf, Tools (7 tools), History, Command |
| Motion | `Design/Motion.swift` | Named springs, state-driven reveal tiers, shared elements via one namespace, Reduce Motion and Low Power variants |
| Rendering | `Design/Materials.swift`, `Graphics/*`, `Resources/LiquidGlass.metal` | Balanced = `NSVisualEffectView`; Ultra = ScreenCaptureKit 10 fps + on-demand `MTKView` with a silhouette SDF |

## Activity, notifications and integrations

- **Single input path:** `EventBridge` watches the owner-only inbox `~/Library/Application Support/NotchFlow/inbox` (DispatchSource, no polling) and decodes `ActivityEvent` contract **v1** (`version`, `source`, `activityId`, `phase`, `title`, optional `summary`, `progress`, `actionURL`, `expiresAt`).
- **Store:** `ActivityQueue` (NotchCore) keyed by `source:activityId`; newer timestamps replace, older are ignored; 200-record cap; `visible()` hides terminal, snoozed and expired records. Persisted whole to `activities.json`.
- **Attention:** `AttentionCenter` (NotchCore) maps phase → priority and decides present / queue / indicate / ignore, with throttling and editing suppression.
- **Claude Code:** `Scripts/notchflow.py claude-hook` maps only `SessionStart` → started, `Notification` (`permission_prompt` | `idle_prompt`) → waiting, `Stop` → completed, one record per `session_id`. No tool state, no session registry, no permission responses. It is a command hook the user installs by hand; nothing is installed on this Mac.
- **Other sources:** CLI `emit` / `run` (wrapper with heartbeat), the focus timer (in-app), nothing for GitHub, Codex, downloads or the clipboard.

## Confirming the brief's assumptions

| Claim | Finding |
| --- | --- |
| Notch and popovers partially disconnected | Mostly addressed: glance and workspace are one silhouette. The glance can only show one item. |
| Notifications could become actionable | True: glance actions are *View* and *dismiss*; detail has *Return to task*, *Snooze*, *Remove*. |
| Concurrent activities need orchestration | True: interruptions are queued, but there is no grouped/stacked presentation and the band shows only one status. |
| Claude activity could be a command center | True: three hook events, no sessions, no approvals. |
| Developer workflows could be first-class | True: no CI provider. |
| Animation needs consistent physics | Largely in place (single commit path, interruptible springs, verified frame by frame). The playing-music waveform uses a repeating symbol effect — a continuous render loop while music plays; to be removed. |
| Context awareness could reduce navigation | True: none exists. |
| Needs feature architecture and extension points | True: no provider abstraction; every source is hard-wired into `AppModel`. |

## Persistence

| Store | Contents | Migration need |
| --- | --- | --- |
| SwiftData `workspace.store` | `Note`, `Todo`, `ShelfFile` (security-scoped bookmark) | Adding entities (e.g. clipboard) is additive |
| `activities.json` | `ActivityQueue` | Must keep decoding v1 records; new optional fields decode as absent |
| `UserDefaults` | Preferences, `countdown` | New keys only |
| Files | inbox, `debug/` (Debug builds) | — |

## Baseline performance

| Measure | Value | Source |
| --- | --- | --- |
| Idle CPU, collapsed | 0.0–0.3 % (mean ≈ 0.1 %), 60 s | `top`, previous build |
| Idle memory | 36–40 MB at launch; 63 MB after a session with interaction (peak 131 MB) | `footprint` |
| Timers at rest | None, except the 1 s clock while a focus timer counts and media polling (2 s) only while Music is visible | Code |
| GPU at rest | None (no display link; `MTKView` paused) except the music waveform symbol effect while playing | Code |
| Window positioning | Verified on one notched display; multi-display untested | Window list |

A 30-minute idle run was cut short at 2 minutes when the app was quit and relaunched during use; it is repeated at the end of this work. Instruments was not run.
