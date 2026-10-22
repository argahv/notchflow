# Sixth Sense: implementation plan, status and roadmap

Status is as of the `feature/sixth-sense` branch. "Done" means implemented, wired into the app, covered by
tests and checked in the running app (see [03-verification.md](03-verification.md)). Nothing below is
claimed beyond that.

## Dependencies

```
Phase 0 audit ─► Context events + gate ─► Intent engine ─► Suggestion glance ─► (Phase 3) more rules and sources
                         │                     │                   ▲
                         ▼                     ▼                   │
                  Context observers      Action catalog + guard ──┘──► (Phase 4) workflows, voice commands
                         │                                         
                         ▼                                         
                  Privacy catalog ─► Settings › What NotchFlow observes
Surface tiers (arbiter) ─► AttentionCenter.holdBelow ─► one resume path for suggestions, screenshots, sound, alerts
Context observers ─► Work modes (ModeRules + ModeTracker) ─► shortcuts, suggestion tilt, ranking
```

## Phase 0: repository audit · Done

[00-audit.md](00-audit.md): architecture map, feature inventory against the brief, debt, constraints,
reusable pieces, risks, and the measured baseline.

## Phase 1: core foundation · Done

| Item | Where | Status |
|---|---|---|
| Typed, privacy-classified context events | `NotchCore/ContextEvents.swift` | Done: three sources (app in front, clipboard, finished downloads), three privacy classes |
| Coalescing, dedupe, debounce | `ContextGate` | Done, 8 tests |
| Observers with a lifecycle, stopped when unused | `Features/ContextEngine.swift` | Done: each runs only while a feature consumes it |
| Rules-first intent engine with explainable scores | `NotchCore/IntentEngine.swift` | Done: 13 rules (9 for copies, 4 for downloads), 12 hold reasons, tested in `IntentEngineTests` and `FlowGuardianTests` |
| Cooldowns, dedupe, dismissal backoff, hourly cap, quiet hours, sensitivity, per-kind switches, global switch | same | Done |
| Minimal, resettable local learning | `IntentLearning` | Done: counts per rule only; Reset and Unmute in Settings |
| Action declarations and one capability check | `NotchCore/ActionCatalog.swift` | Done for all 31 Notch Actions and 10 suggested actions; both runners pass `ActionGuard` |
| Written-down surface priority | `NotchCore/SurfacePriority.swift` | Done for every transient glance (suggestions, screenshots, sound, alerts), with one resume path |
| Context Inspector | Settings › Diagnostics; Debug `status` | Done; redacted |
| Privacy and permission framework | `NotchCore/PrivacyCatalog.swift`, Settings › What NotchFlow observes | Done: 15 capabilities; Reminders asked in context |

Phase 1 acceptance criteria from the brief:

- *Events are typed and testable*: a closed enum per source; gate and engine tested with fixed dates.
- *Features can enable and disable their observers*: `ContextEngine.setEnabled`, driven by preferences. The
  inspector shows each source as running or stopped.
- *Suggestions can be ranked and dismissed*: score components, threshold, dismissal backoff and muting.
- *No duplicate event-triggered surfaces*: one suggestion at a time. A newer copy replaces it in place, and
  a suggestion waits rather than opening a second glance. Downloads and screenshots keep their own existing
  glances, and no suggestion duplicates them.
- *Existing notch features continue working*: all 110 original tests pass unchanged, and the app-in-front
  boost behaves as before through the new observer.

## Phase 2: the Magic Notch · Done where it was missing

| Item | Status |
|---|---|
| Magic Drop | Already shipped (portal, shelf, Notch Actions). Unchanged except that Notch Actions now pass `ActionGuard`. |
| Smart clipboard classification | Done: link, email, phone, color (hex, rgb, rgba), JSON, address, date, file path, code, prose. |
| Contextual suggestions from copies | Done end to end, with actions, Why?, Undo and learning. |
| Contextual suggestions for finished downloads | Done: an archive offers Extract, a PDF Extract Text and its actions, an image, video or audio file its actions, in place of the download's notice (ADR-9). |
| User-excluded clipboard apps | Done (Settings), on top of the built-in password-manager list. |
| Secret filter fixes | Compact JSON is no longer mistaken for a key; quoted JSON keys (`"api_key": "…"`) are now caught. |
| Universal task progress | Already shipped (activity engine). |
| Fluid transitions | The suggestion glance is the same silhouette, sized by a size contract and animated through `AppModel.commit`; "Why?" deepens the shape. |
| UI under simultaneous events | Done: one coordinator decides what waits and what goes next. A screenshot waits behind a suggestion; a failure takes the surface from a screenshot, which returns; a stale sound change is dropped; a stuck-alert bug on collapse is fixed. |
| Semantic clipboard search | **Deferred.** Needs an embedding model and an index; history is memory-only and capped at 40 items, so plain search covers it today. |
| Encrypted clipboard persistence | **Not done, on purpose.** History stays memory-only, which is stronger than encryption at rest. |

## Phase 3: the Adaptive Notch · Started

| Item | Status |
|---|---|
| Intent Switch (work modes) | **Done.** Six modes, inferred from the app in front, a call in progress and media playing, with hysteresis, an explicit pin, per-signal switches, reasons in the glance and the inspector. Changes shortcuts, suggestion scores and ranking. ADR-8. |
| Meeting context | Partly: Meeting mode switches at once when a call is in progress, offers Calendar, Notes and Sound, ranks the call first and quiets suggestions. Microphone and camera state stay out of reach (no public API). |
| Media context | Partly: Media mode from the player in front or music playing; the shortcuts lead to Music and Sound. |
| Developer context | Partly: Developer mode from editors and terminals; agents, builds and CI rank first. Git status and build output need the inbox contract to carry them. |
| Workspace snapshots and restore | Not started (P2 below). |

## Phase 4: the Sixth Sense · Started

| Item | Status |
|---|---|
| Flow Guardian | **Done** for NotchFlow's own previews: during a focus timer only needs-input and failures come through, the rest waits and is counted, and the end says what waited with Review (ADR-9). Reading or holding other apps' notifications, or macOS Focus, isn't possible with public APIs. |
| Predictive ranking improvements | Partly: per-rule learning, work-mode tilt and finished downloads. More sources are below. |
| Voice, Teach My Mac, companion | Not started (below). |

## Phase 3–5: roadmap

Ordered by priority. Each item lists what it builds on and the platform reality.

| Priority | Item | Builds on | Notes and limits |
|---|---|---|---|
| P1 | A Study session that starts the focus timer and quiets everything but its own kinds | Work modes, focus timer | Study is chosen, never inferred. |
| P2 | Workspace snapshots and restore | New observer; Accessibility for window frames; per-browser Automation for URLs | Must report what couldn't be restored. Accessibility is a large permission; ask only when the feature is turned on. |
| P2 | Teach My Mac workflows | `ActionCatalog` descriptors as steps, context events as triggers, `ActionGuard` for each step | No shell or AI-generated commands; previews and history per run. |
| P2 | Extension providers (context and action) | The inbox spool contract, extended with typed context events | Host-rendered UI only; per-extension capabilities checked by `ActionGuard`. |
| P2 | Meeting Guardian during calls | `MeetingProvider` | No public API reports another app's microphone or camera state; Presentation stays the user's Hide private details switch. |
| P3 | Voice actions | `SFSpeechRecognizer`; commands map onto `SuggestedAction` and `ContentAction` | Push-to-talk only; microphone and speech permissions asked on first use. |
| P3 | iPhone companion | A separate iOS app; Network.framework discovery and pairing | NotchFlow must keep working without it. No AirTag location API exists. |
| P3 | Optional local summarize and rewrite | A configured on-device provider | Only offered when a provider is configured; never the default path. |

## Commits on this branch

1. `Sixth Sense core`: NotchCore types and 47 tests, plus the audit and the architecture decisions.
2. `Suggest a next step for what you copy`: app integration, Settings, privacy catalog UI, inspector, QA
   commands, and the secret-filter fixes.
3. Documentation, verification record, README and CONTRIBUTING updates, and the `ActionGuard` check on Notch Actions.
4. `Give everything that waits for the notch one coordinator`: screenshots and sound on the arbiter, one
   resume path, and the stuck-alert fix.
5. `Intent Switch`: work modes, their effects, Settings, ⌘K, privacy entry, QA hooks.
6. Documentation for 4 and 5.
7. `Suggest a next step for finished downloads, and say what waited during a focus session`, plus a Debug switch
   that ignores the real pointer during scripted runs.
8. Documentation for 7.
