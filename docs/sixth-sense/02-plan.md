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
Surface tiers (arbiter) ─► AttentionCenter.holdBelow ─► suggestion coordination ─► (later) capture and sound glances
```

## Phase 0: repository audit · Done

[00-audit.md](00-audit.md): architecture map, feature inventory against the brief, debt, constraints,
reusable pieces, risks, and the measured baseline.

## Phase 1: core foundation · Done

| Item | Where | Status |
|---|---|---|
| Typed, privacy-classified context events | `NotchCore/ContextEvents.swift` | Done: two sources (app in front, clipboard), three privacy classes |
| Coalescing, dedupe, debounce | `ContextGate` | Done, 8 tests |
| Observers with a lifecycle, stopped when unused | `Features/ContextEngine.swift` | Done: each runs only while a feature consumes it |
| Rules-first intent engine with explainable scores | `NotchCore/IntentEngine.swift` | Done: 9 rules, 11 hold reasons, 17 tests |
| Cooldowns, dedupe, dismissal backoff, hourly cap, quiet hours, sensitivity, per-kind switches, global switch | same | Done |
| Minimal, resettable local learning | `IntentLearning` | Done: counts per rule only; Reset and Unmute in Settings |
| Action declarations and one capability check | `NotchCore/ActionCatalog.swift` | Done for all 31 Notch Actions and 10 suggested actions; both runners pass `ActionGuard` |
| Written-down surface priority | `NotchCore/SurfacePriority.swift` | Done for suggestions and activity alerts; capture and sound glances keep their own waiting rules (see below) |
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
| User-excluded clipboard apps | Done (Settings), on top of the built-in password-manager list. |
| Secret filter fixes | Compact JSON is no longer mistaken for a key; quoted JSON keys (`"api_key": "…"`) are now caught. |
| Universal task progress | Already shipped (activity engine). |
| Fluid transitions | The suggestion glance is the same silhouette, sized by a size contract and animated through `AppModel.commit`; "Why?" deepens the shape. |
| Semantic clipboard search | **Deferred.** Needs an embedding model and an index; history is memory-only and capped at 40 items, so plain search covers it today. |
| Encrypted clipboard persistence | **Not done, on purpose.** History stays memory-only, which is stronger than encryption at rest. |

## Phase 3–5: roadmap

Ordered by priority. Each item lists what it builds on and the platform reality.

| Priority | Item | Builds on | Notes and limits |
|---|---|---|---|
| P1 | More suggestion rules from existing sources: an archive download → Extract; a finished download → Keep on Shelf | Intent engine; Download Center events become context events | Must replace, not duplicate, the download glance's own button. |
| P1 | Move the Screenshot Magnet and Sound Island onto `SurfaceArbiter` | Surface tiers | Changes visible behavior (a screenshot would wait for the sound glance); needs on-screen verification of both. |
| P1 | Flow Guardian summary: "Focus session completed · 48 min · 3 updates deferred" | Focus timer, `AttentionCenter.pending` | No public API reads macOS Focus without an entitlement; this would cover NotchFlow's own deferrals only. |
| P1 | Inferred modes (Developer, Meeting, Media) with an explicit pin | Context engine; `ProductMode` presets | Inference only from wired sources; an explicit choice always wins. |
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
