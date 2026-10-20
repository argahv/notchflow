# Liquid Workspace 2.0 — implementation progress

Branch `feat/liquid-workspace-2`. Status as of 2026-10-20.

- **Implemented** means the code is in place and builds (Debug and Release).
- **Tested** means automated tests cover it, and/or it was verified end to end on the development Mac
  (see [acceptance-tests.md](../testing/acceptance-tests.md)).
- **Partial** means it works with stated limits.
- **Blocked** means it needs something outside this repository.
- **Not started** means just that.

Automated: 48 Swift tests (`swift test`) and 22 Python tests (`python3 -I Tests/test_bridge.py`), all passing.

| Phase | Area | Status | Notes |
|---|---|---|---|
| 0 | Audit (current state, integration inventory, roadmap) | Implemented | `docs/architecture/current-state.md`, `integration-inventory.md`, `redesign-roadmap.md` |
| 1 | Idle cost fix (static waveform at rest) | Implemented, Tested | Idle numbers below |
| 2 | Unified activity engine (v2 contract, states, categories, ranking, provider contract, history-safe persistence) | Implemented, Tested | [activity-engine.md](../architecture/activity-engine.md) |
| 3 | Dynamic task stack (band dots, glance layers, filters, retraction, pin, hide, failure window) | Implemented, Tested | Verified with captures |
| 4 | Agent command center (Claude Code, Codex hooks; permission answers; Open host app) | Implemented, Tested | Simulated payloads end to end via real processes. A **live Claude Code / Codex session is Blocked on installing the hooks in your settings** (NotchFlow doesn't edit them). Codex isn't installed on the development Mac. |
| 5 | GitHub Actions provider | Implemented, Tested | Unauthenticated live polling verified. The **token path is Blocked on your token** (entered by you in Settings). No webhooks (no public endpoint). |
| 6 | Clipboard (opt-in, memory only) | Implemented, Partial | Text only, no images. Real pasteboard round trip not exercised (to avoid touching your clipboard). Secret detection is best effort. |
| 6 | Download Center | Implemented, Tested | Scratch folder verified. Real ~/Downloads access prompt is manual. No percentages, because browsers don't expose them. |
| 6 | Meeting companion | Implemented, Partial | Link extraction tested. **Live check Blocked on Calendar access** (not granted on the development Mac). |
| 6 | Sound output, on-demand system metrics | Implemented, Tested | Switching outputs wasn't exercised (it would change your audio). |
| 6 | Low-battery alerts | Implemented, Tested | Threshold logic tested; a live drain is manual. |
| 6 | Command palette additions | Implemented | New tools appear automatically; mode commands added |
| 7 | Context engine | Implemented, Tested | [context-engine.md](../architecture/context-engine.md) |
| 7 | Product modes (Minimal / Dynamic / Developer) | Implemented, Tested | Presets; defaults read as Dynamic |
| 8 | Interactive notifications (Review / Join / Show in Finder / Open run) | Implemented, Tested | |
| 8 | Motion 2.0 | Partial | Stack, retraction, filter and prompt motion done ([motion-system.md](../design/motion-system.md)). The surface-level rework is deferred to the Obsidian & Silver redesign. |
| 9 | Permissions status in Settings | Implemented | Calendar, Reminders, Camera, Downloads |
| 9 | Security and privacy documentation | Implemented | [security/integrations.md](../security/integrations.md) |
| 9 | Accessibility | Partial | New controls have labels, hints, selected traits and header traits. A full VoiceOver pass by a person hasn't been done. |
| — | Webhooks, remote CI other than GitHub, MCP, embedded prompt input to agents | Not started | Out of scope: no verified local interface for these |

## Idle cost (30 minutes, at rest)

Measured with `top -l 181 -s 10` (30 minutes, 181 samples) on the Debug build, 2026-10-20 23:33–00:07,
while the Mac was in normal use (other apps active, and the notch sometimes hovered or opened).

| | Result |
|---|---|
| Samples at rest (91% of the run) | 0.12% CPU on average; 110 of 181 samples read 0.0% |
| Idle wakeups at rest | ≈0.12 per second |
| Spikes | Up to 14% for 10–30 s at a time, in clusters that match the notch being hovered or opened |
| Memory | Physical footprint 26 MB at start, 52 MB at the end. Growth after opening the workspace hasn't been investigated yet (view caches vs. a leak); it's tracked for the Obsidian & Silver validation phase. |

With every opt-in off (the defaults), nothing polls at rest. Opt-ins add their own documented cadence:
clipboard about 1 check/s, GitHub every 15–180 s, downloads only while a file is downloading, meetings
only at event boundaries.

## Known limits

- Hook bursts are ordered by millisecond timestamps taken when each hook process starts. Claude's
  background (`async`) status hooks can very rarely start out of order; the next event corrects the card.
- Codex `notify` and Codex hooks aren't documented to share an id, so use one or the other.
- "Open ‹host app›" brings the app forward and can't choose a tab.
- GitHub Actions has no completion fraction, so runs show a spinner.
