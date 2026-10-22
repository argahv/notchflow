# Sixth Sense: architecture decisions

The brief asks for four foundational systems. NotchFlow already has strong versions of two of them, so
this branch adds what's missing and connects it to what exists, instead of building a parallel app.

```
 observers (app)            NotchCore (pure, tested)                      app
 ───────────────            ─────────────────────────────────────         ──────────────────────────
 FrontmostAppObserver ─┐                                                   ┌─ activity ranking boost
 ClipboardObserver ────┼─► ContextEvent ─► ContextGate ─► IntentEngine ─► Suggestion ─► SurfaceArbiter ─► suggestion glance
 (more later)         ─┘    typed, privacy-   coalesce,    rules, score,     actions         tiers             │
                            classified        dedupe,      cooldowns,                                         ▼
                                              debounce     learning                       ActionCatalog + ActionGuard ─► SuggestionActions
                                                                                          (declared capability)          (executor)
```

## ADR-1 · Context events are typed, privacy-classified, and never persisted

`ContextEvent` (`NotchCore/ContextEvents.swift`) wraps one `ContextSignal`, a closed enum with an associated
value per source. Every signal has a `PrivacyClass`:

| Class | Example | Logged in the inspector | Persisted | Used while details are hidden |
|---|---|---|---|---|
| `system` | display or power changes | in full | no | yes |
| `activity` | which app is in front | app name only | no | yes (ranking only) |
| `content` | what was copied, a finished download's name | kind and length or size only | **never** | **no** |

**Why a closed enum rather than a dictionary payload:** the brief asks for typed, testable events, and a
closed enum means every new source is a compile-time decision with a privacy class attached.

Only sources that are actually wired have a case. There is no `meetingStateChanged` with nothing behind it.

## ADR-2 · Coalescing is pure and deterministic

`ContextGate` decides, per source, whether an event passes, is a duplicate (same fingerprint within the
source's repeat window), or is deferred (inside the source's minimum interval; the latest deferred event
wins and the app flushes it when the interval ends). Rapid ⌘-Tab cycling therefore settles on the app you
land on, and copying the same thing twice in a row doesn't count twice. Because fingerprints are in-memory
`Hasher` values, nothing derived from content outlives the process.

## ADR-3 · Observers have a lifecycle and stop when nothing needs them

`ContextObserver` (app side) mirrors the existing `ActivityProvider`: `start(emit)`, `stop()`, and a status
for Settings. `ContextEngine` starts an observer only while a feature that consumes it is on:

| Observer | Runs while | Mechanism |
|---|---|---|
| Frontmost app | "Follow the app in front" or "Follow what I'm doing" (work mode) is on. A copy carries the app it was made in, so suggestions don't need this observer | `NSWorkspace.didActivateApplicationNotification`; no polling |
| Clipboard | clipboard history **or** copy suggestions are on | the existing `changeCount` comparison (macOS has no change notification); one shared poll |
| Finished downloads | download suggestions are on | handed over by the activity engine when any provider reports a completed download; the file's type and size are read, never its contents |

## ADR-4 · Intent is rules-first, explainable, and works with no model configured

`IntentEngine` (`NotchCore/IntentEngine.swift`) maps an event to at most one `Suggestion`. No LLM, no
network, no embeddings. The score is a sum of named components, so "Why this suggestion?" is the score
itself rather than a story told after the fact:

| Component | Range | Source |
|---|---|---|
| Rule match | 0.45–0.8 | how specific the rule is (a JSON document is less ambiguous than a long text) |
| Detection confidence | ×0.6–1.0 | how much of the copied text the detected entity covers |
| Context | −0.25…+0.1 | e.g. "Open link" scores lower when the link was copied *in a browser* |
| Time sensitivity | 0…+0.1 | e.g. a date in the next week |
| Learned preference | −0.3…+0.2 | accepted vs dismissed for this rule, on this Mac |
| Recent prompts | −0.05 each | suggestions shown in the last hour |

The threshold depends on sensitivity (Fewer 0.72, Balanced 0.6, More 0.48).

Gates run before scoring, and each one reports a reason to the inspector: predictions off, category off,
details hidden (content signals), quiet mode, quiet hours, the rule cooling down, the rule muted after
repeated dismissals, the same content suggested recently, the hourly cap.

**Learning is minimal and resettable.** `IntentLearning` stores, per rule id, counts of accepted,
dismissed and ignored suggestions, the current run of consecutive dismissals, and two timestamps. No
content, no app names, no history. Consecutive dismissals back off exponentially (2, 4, 8, 16 minutes…)
and five in a row mute the rule until the person resets learning or unmutes it in Settings, which forgets
that rule's dismissals. Dedupe keys and recent-prompt times live in `IntentSession`, which is memory only.
Reset Learning clears both.

Each prompt in the last hour lowers the next score by 0.05, so under Balanced a mid-scoring rule stops
appearing after two or three suggestions in an hour, while strong or often-used ones still get through. The
hourly cap of six is the hard ceiling.

## ADR-5 · Actions declare their capability; execution stays where it is

`ActionCatalog` (`NotchCore/ActionCatalog.swift`) gives every action, the 31 existing `ContentAction`s and
the new `SuggestedAction`s, one `ActionDescriptor`: inputs, outputs, required permissions, impact,
confirmation, cancellation and undo. `ActionGuard.clearance` is the single check before anything runs, in
both runners. It returns missing permissions, which the suggestion asks macOS for in context before
continuing, and requires confirmation for anything destructive whatever the descriptor says. Nothing in
either catalog is destructive today, and a test keeps it that way. Network use is declared (`impact:
.network`, only Fetch Title) and tested; it isn't enforced at run time, because no runner has a network
path except that one action.

**Why not rewrite the executor:** `ContentActionRunner` and `ActionRun` already handle tokens,
progress, cancellation and undo correctly. The brief's gap was declaration and a capability boundary, not
execution.

## ADR-6 · One tier model for the surface

`SurfaceArbiter` (`NotchCore/SurfacePriority.swift`) writes down the brief's six tiers: the person's own
interaction (1), critical actionable work (2), task progress (3), time-sensitive suggestions (4), passive
news (5), idle (6). The rules:

1. Nothing takes the surface from the person: a drag, a drop's result, an editor or the open workspace.
2. Only critical, actionable work preempts another glance.
3. Everything else waits its turn and replays when the surface is free, if it's still fresh.

`AttentionCenter` gains `holdBelow`: while a suggestion shows, passive and progress news waits behind
it, and needs-input or failures still take the surface. A suggestion displaced that way counts as
superseded, not dismissed, so it doesn't teach the engine anything.

Every transient glance follows these rules: suggestions, the Screenshot Magnet, Sound Island and alerts.
Anything that has to wait is resumed from one place, `AppModel.resumeSurface`. When a glance ends,
`SurfaceArbiter.next` picks the most important waiting glance, then the most recent, and drops anything
stale: a sound change after six seconds, a screenshot after ninety, a suggestion after forty-five.

This changed two visible behaviors on purpose. A screenshot or sound change now waits behind a suggestion
or under the pointer instead of replacing it; sound used to be dropped when the notch was busy. And
needs-input or failures now take the surface from a screenshot or sound glance; a displaced screenshot
comes back afterwards. It also fixed a stuck-alert bug: collapsing the notch while an alert showed made
the next queued alert "current" without showing it (`dismissCurrent`'s result was discarded).
`AttentionCenter.closeCurrent` closes without promoting anything, and a test pins the old pitfall.

## ADR-7 · Privacy is described by data

`PrivacyCatalog` (`NotchCore/PrivacyCatalog.swift`) lists every capability that observes anything: what
it observes, why, whether anything leaves the Mac, the macOS permission, where data is kept, how to turn
it off and how to clear it. Settings › Privacy renders it, and tests check that every context source has
an entry and that only capabilities that genuinely use the network say so.

## ADR-8 · Work modes change what's offered, never whether the notch opens

`WorkMode` (`NotchCore/WorkModes.swift`) is the brief's Intent Switch: General, Developer, Meeting, Media,
Creative, Study. `ModeRules.read` turns signals NotchFlow already has into a mode and a plain reason (a
call in progress first, then the app in front, then media playing). `ModeTracker` makes a different
reading hold for fifteen seconds before the mode changes; a call switches at once. Study is never inferred.

| Effect | How |
|---|---|
| Shortcuts on hover | Three per mode; General keeps Music, Shelf and Tools. A line says which mode and why, with a pin. |
| Suggestions | A named score component per mode, for example "Creative mode +0.08" for colors, "In a call −0.15" for most kinds. |
| Ranking | `WorkMode.boosted` joins the app-in-front boost, while ranking follows the app in front or when the mode is pinned. |

**Why not reuse `ProductMode`:** that's a preset that writes settings once (Minimal, Dynamic, Developer).
A work mode is live state that never changes a setting. The names stay apart in the UI: "Use Developer
mode" applies a preset, and "Pin Developer work mode" pins a work mode.

**Explicit beats inferred:** a pinned mode wins until unpinned, and switching inference off returns to
General. Each signal can be switched off. The app-in-front observer runs while either ranking or mode
inference needs it.

## ADR-9 · A finished download gets one glance, and a focus session one summary

**Downloads.** When a completed download arrives, the engine is asked first. If a rule fits (an archive,
a PDF, an image, video or audio), its suggestion replaces the download's plain notice; otherwise the notice
shows as before. Either way it's one glance. Extract hands an archive to Archive Utility, and Actions keep
the file on the shelf by reference before opening Notch Actions. The existing rule that a download is
revealed, never opened, still holds: nothing is opened or run, and disk images and installer packages
aren't treated as archives.

**Flow Guardian.** While a focus timer runs, `AttentionContext.holdBelow` rises to needs-input, and
suggestions are held with their own reason. What's held is counted in a `FocusLedger`, in memory, without
pauses counting as focus. The session's end is the existing Mission Complete moment with a summary ("25 min ·
2 updates and 1 suggestion waited") and Review. What waited is discarded from the alert queue, so it isn't
replayed one glance at a time: it's in the stack and History. macOS offers no public way to hold other apps'
notifications or read Focus, so this covers NotchFlow's own previews only.

## What this branch deliberately does not do

- No LLM summarise/rewrite: the brief makes them conditional on a configured provider, and none exists.
- No semantic clipboard search, voice, workspace snapshots, device companion, workflow builder or
  extension SDK. See [02-plan.md](02-plan.md) for their order, dependencies and what each needs.
- No change to Magic Drop, Live Activities or the renderer beyond the new glance, because they already
  meet the brief.
