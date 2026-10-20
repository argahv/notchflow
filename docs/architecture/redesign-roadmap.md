# Liquid Workspace 2.0 — implementation roadmap

File-specific plan derived from `current-state.md` and `integration-inventory.md`. Each phase ends with a build, both test suites and a commit on `feat/liquid-workspace-2`. Progress is tracked in `docs/implementation/progress.md`.

## Phase 1 — Stabilization
- `Shell/OverlayView.swift`: replace the repeating music waveform effect (continuous render loop) with a static glyph and a one-shot change cue.

## Phase 2 — Unified activity engine (NotchCore first, tested)
- `NotchCore/Activity.swift`: event contract **v2**, backward compatible with v1: optional `category`, `state` (queued … unknown), `project`, `branch`, `groupKey`, `parentId`, `sensitive`, `agent` metadata, actionable `request`. `ActivityRecord` gains `firstSeen`, `pinned`, `dismissedAt`. Equal-timestamp updates never move a terminal record back to running.
- `NotchCore/ActivityRanking.swift` (new): deterministic priority with user-interaction, actionable-request, severity, context, pin and recency terms.
- `AppModel.swift`: persist a history-safe copy (drop request details and sensitive summaries).
- `Features/Providers.swift` (new): `ActivityProvider` contract and `ProviderHub` (enable/disable/start/stop/status, failure isolation). `EventBridge` becomes the inbox provider.

## Phase 3 — Dynamic task stack
- Band: grouped indicator (stacked tone dots + count) when several tasks are live.
- Glance: lead activity with stacked layers and a "+N" chip that opens the stack.
- `Surfaces/ActivitySurface.swift`: category filter (All · Agents · CI · Downloads · Done), pin, dismiss-from-stack (kept in History), remove-from-History, completion retraction into History.

## Phase 4 — Agent command center
- `Scripts/notchflow.py`: `agent-hook --provider claude|codex` (session, tool, permission, stop/end mapping; never forwards prompts or assistant text), `approval` wait with nonce + response file, `codex-notify`. Existing `claude-hook` kept for compatibility.
- `Features/AgentApprovals.swift` (new): writes owner-only responses; presence file so hooks skip waiting when the app is not running.
- `Surfaces/AgentsSurface.swift` (new): session cards grouped by project, actionable requests first; *Allow once* (two-step), *Deny*, *Open terminal app*.

## Phase 5 — GitHub Actions
- `NotchCore/GitHubRuns.swift` (new): run/job JSON → activity mapping (tested with fixtures).
- `Features/GitHubProvider.swift` (new): ETag polling with adaptive cadence, backoff, rate-limit handling; Keychain token; repositories from Settings and from agent sessions' remotes.

## Phase 6 — Productivity
- Clipboard (`Features/ClipboardService.swift`, `Surfaces/ClipboardSurface.swift`, `NotchCore/ClipClassifier.swift`): opt-in, exclusions, retention, smart actions.
- Downloads (`Features/DownloadsProvider.swift`): directory watch, temp-file aware states.
- Command palette additions; meeting companion (`CalendarService` next meeting + join-link extraction in NotchCore); Sound (Core Audio output switching), power alerts, on-demand system metrics.

## Phase 7 — Context and modes
- `NotchCore/ContextRules.swift` + `Features/ContextService.swift`: frontmost-app category → ranking boosts and glance preference; user overrides.
- Product modes (Minimal, Dynamic, Developer) as presets over shared preferences.

## Phase 8–9 — Motion polish and hardening
- Shared elements for stack, agent card, CI detail, shelf, timer; accessibility labels; permission status in Settings; idle profiling; documentation set under `docs/architecture`, `docs/design`, `docs/security`, `docs/testing`, `docs/implementation`.
