# Activity engine

Everything NotchFlow shows about ongoing work, including agents, builds, CI, downloads, meetings, timers and
system notices, goes through one typed model and one queue. Sources: `Sources/NotchCore/Activity.swift`,
`ActivityRanking.swift`, `Attention.swift`; app side `AppModel.ingest`, `Features/Providers.swift`.

## Contract

`ActivityEvent` is versioned JSON. Version 1, `{version, source, activityId, phase, title, summary?,
timestamp, progress?, actionURL?, expiresAt?}`, is unchanged, so old publishers and stored History still
decode. Version 2 adds optional fields:

| Field | Meaning |
|---|---|
| `state` | `queued`, `starting`, `running`, `waiting`, `needsInput`, `paused`, `completed`, `failed`, `cancelled`, `unknown`. Must agree with `phase` (terminal ⇔ terminal). |
| `category` | `task`, `agent`, `build`, `deploy`, `ci`, `download`, `timer`, `meeting`, `system` |
| `project`, `branch`, `groupKey`, `parentId` | Association and grouping (length-limited) |
| `agent` | `{provider, sessionId, state?, tool?, terminal?, repository?}`; `state` is the agent's own (`executingTool`, `awaitingAuthorization`, …) |
| `request` | A pending permission request `{id, nonce, kind, tool, detail?, expiresAt}`. Only on `needsInput` agent events, and it expires within 10 minutes. |
| `sensitive` | The summary isn't written to disk |

`validate()` checks lengths, the progress range, URL schemes (`https`, `http` with a host, `file`, `vscode`),
the timestamp window (−7 days … +5 minutes), expiry after timestamp, and that version 1 events carry no
version 2 fields. `Scripts/notchflow.py validate()` mirrors it, and fixture tests keep the two in step.
Timestamps may carry milliseconds; the inbox applies each batch oldest first.

## Queue and lifecycle

`ActivityQueue` holds the latest event per `source:activityId` (200 records at most):

- Older timestamps are ignored. At the same instant, a terminal state never goes back to running.
- A state change clears "hidden from stack" (`dismissedAt`), so new attention brings a card back.
- **Stack** (`visible`): live work that isn't snoozed, hidden or expired, plus failures from the last hour
  (`failureWindow`). Pinned records always stay.
- **History**: every record, pruned by the retention setting (default 30 days), with pinned and live work
  kept. History on disk is `historySafe`: pending requests are removed, and sensitive summaries are dropped.
- Hide (stack only), Remove (History) and the task's own lifecycle are separate actions. Hiding a
  notification never cancels anything.

## Priority and ranking

`AttentionPriority(state:)`: failed → critical; needsInput/waiting → action required; completed →
informational; running-ish → background; cancelled → silent. `AttentionCenter` decides
present/queue/indicate/ignore from priority, quiet mode, focus and editing.

`ActivityRanking.score`:

| Tier | Score |
|---|---|
| Agent failure | 800 |
| Needs input with an answerable request | 760 |
| Needs input / waiting | 700 |
| Pipeline failure (CI, build, deploy, download) | 600 |
| Running, boosted by context | 500 |
| Running | 300 |
| Completed | 200 |
| Cancelled | 100 |

Non-running tiers get +20 when boosted, and +40 when pinned. Ties go to the most recent, then the id. A
score of 600 or more outranks music in the resting notch.

**News vs. updates.** `isMaterialChange(from:)` (a new record, state, request or title) is what notifies.
Heartbeats, progress ticks, tool-by-tool agent updates, expiry refreshes and a withdrawn request update the
row quietly.

## Presentation

- **Resting band**: up to three tone dots and a count when several things are active; the most urgent
  leads.
- **Glance**: the top-ranked record, with the next one or two showing as stacked layers that grow into
  rows when opened (shared geometry `stack-<id>`). Its primary action matches the record: Review, Join,
  Show in Finder, Open run, or View.
- **Stack** (Activity): filters All / Agents / CI / Downloads / Done. Rows keep their order while it's
  open. Work that newly needs you moves to the top. Finished tasks retract into History after 6 seconds,
  with a pulse on the History dock button. Agents are grouped by project when more than one project is
  active. The filter bar stays put, and the opened card scrolls into view.

## Providers

`ActivityProvider` (`start(context)`, `stop()`, `report(status)`) isolates each source; `ProviderHub`
enables them from preferences and keeps their status for Settings.

| Provider | Source | Default |
|---|---|---|
| `inbox` | Owner-only JSON spool (CLI, command wrapper, agent hooks) | On |
| `github` | GitHub Actions REST polling ([INTEGRATIONS.md](../INTEGRATIONS.md)) | Off |
| `downloads` | Downloads folder watcher | Off |
| `meetings` | Calendar events with a join link | Off |

Battery alerts and timers are produced by the app model directly. See also
[agent-integrations.md](agent-integrations.md) and [context-engine.md](context-engine.md).

## Tests

`Tests/NotchCoreTests/ActivityEngineTests.swift` (contract, ordering, dismissal, pinning, failure window,
milliseconds, material changes), `NotchCoreTests.swift`, `LiquidWorkspaceTests.swift`,
`GitHubRunsTests.swift`, `ContentRulesTests.swift`, `ContextRulesTests.swift`; `Tests/test_bridge.py` for the
CLI and hooks.
