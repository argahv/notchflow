# Sixth Sense 2.0: state, gaps and what this branch adds

Audited on 2026-10-22 for the "Sixth Sense 2.0" continuation brief, on `feature/sixth-sense-expansion`, cut
from `feature/sixth-sense` after merging `origin/main` (`4dc3c78`, the owner's README section on the twelve
directions). "Verified" means unit-tested and exercised in a running build; see [03-verification.md](03-verification.md).
The one roadmap stays in [02-plan.md](02-plan.md).

## Collision check

| Where | State | Risk |
|---|---|---|
| `feature/sixth-sense` (this worktree) | All Sixth Sense work so far, committed, not pushed | None: the expansion branch is cut from it |
| Main checkout, `feat/living-notch` | Clean; a Debug build from it is running on this Mac | None: different branch, separate data folder and bundle id during QA |
| `notchflow-open-source-launch` worktree, `main` | Clean | None |
| `origin/main` `4dc3c78` | README: "What I'm working on next — The Sixth Sense" | Merged into `feature/sixth-sense`; its table now carries a status column instead of a second list |
| PR #17 (Countdown edge-case tests) | Open, external | None: `Countdown.swift` is unchanged here; Flow Guardian only reads it |
| PR #18 (test-runner wrappers in the agent hook) | Open, external | None: `Scripts/notchflow.py` and its tests are unchanged here |

No other session is changing these files, so the expansion builds on the existing contracts directly rather
than through adapters.

## Inventory

Status: **Shipped** (in release 0.2) · **Built** (on these branches, tested, not released) · **Partial** ·
**Planned** · **Blocked** (by a platform limit).

| Feature | What actually exists | Status | Related components | 2.0 opportunity | Action |
|---|---|---|---|---|---|
| Magic Drop | Portal, shelf, 33 Notch Actions incl. QR Code and Create ZIP | Shipped + Built | `PortalRules`, `ShelfService`, `ActionRegistry`, `ActionExecutor` | Batch workflows | Extended (chains) |
| Universal Live Activities | One activity model, stack, glance, History | Shipped; chains report into it | `ActivityQueue`, `AttentionCenter` | Every long action as a task | Integrated |
| Predictive Actions | Rules for copies and finished downloads, learning, Why? | Built | `IntentEngine`, `ContextEngine` | Next Action | Extended |
| Intent Switch | Six work modes, hysteresis, pin, per-signal switches | Built | `WorkModes`, `ModeTracker` | Composable context (2.0) | Planned (below) |
| Flow Guardian | Focus-session holds and summary | Built | `FocusLedger`, `AttentionCenter.holdBelow` | — | No change |
| Memory Shelf | Opt-in clipboard (memory only), shelf, Time Travel; ⌘K now searches shelf and clipboard | Partial | `ClipboardService`, `ShelfService`, `Timeline` | Stage 1 search done; OCR and semantic search next | Extended |
| Meeting Guardian | Join links; Meeting mode quiets suggestions | Partial | `MeetingProvider`, `WorkMode.meeting` | Presentation Mode | Planned |
| Workspace Time Machine | Nothing | Planned | — | Context restore, not just geometry | Planned (needs Accessibility) |
| Universal Voice Actions | Nothing | Planned | — | Commands map onto `ActionCatalog` | Deferred |
| Device Continuity / Pocket-to-Notch | Nothing | Planned | — | Share Extension into the inbox contract | Deferred (needs an iOS app) |
| Teach My Mac | Nothing user-defined yet | Partial foundation | `ActionChain` | Saved chains are its first form | Planned |
| Life Moments | Nothing beyond meeting reminders and the focus timer | Planned | `MeetingProvider`, `Countdown` | Quiet reminders via Calendar/Reminders | Planned |
| **Next Action** (2.0) | After an action makes files, the result offers the usual next step | **Built** | `NextActionRules`, `ActionsSurface` | Text results → Summarize once a local provider exists | New, done |
| **Action Chains** (2.0) | Four presets, one engine, progress, cleanup, Live Activity | **Built** | `ActionChain`, `ChainArtifacts`, `AppModel.runChain` | User-saved chains (Teach My Mac), WebP | New, done |
| **QR Bridge** (2.0) | QR Code action for links; offered for a copied link | **Built** | `ActionExecutor.qrCode`, `IntentRules` | — | New, done |
| **Color Sense** (2.0) | Swatch, hex/RGB/HSL conversions | Built (before 2.0) | `ColorValue` | Palette, recent colors | Partial |
| **Unified Command Bar** (2.0) | ⌘K: commands, activities, now shelf items and clipboard | Partial | `AppModel.commandResults` | Workflows, workspaces, settings | Extended |
| **Agent Rescue** (2.0) | A failed run, build, deploy or agent turn offers Handoff: an editable brief, copied for an agent, nothing sent | **Built** | `AgentRescue`, `HandoffSurface` | Local build output, when a tool reports it safely | New, done |
| **Smart Cleanup** (2.0) | Nothing | Planned | `ShelfService`, `ActionGuard` (destructive → confirm) | Review-first, move to Trash | Deferred |
| **Presentation Mode** (2.0) | Hide private details hides previews and suggestions | Partial | `Preferences.privacy` | Name, shortcut, meeting reminder | Planned |
| **Notch Companions** (2.0) | Nothing | Experiment | — | — | Deferred |

## How the 2.0 contracts map onto what exists (no parallel architecture)

| 2.0 asks for | Existing contract it reuses | Added |
|---|---|---|
| Common artifact model | `ContentKind` for what a thing is, `ShelfFile` for a kept reference, copy, text or link | `ActionChains.output(of:from:)`: what each action makes from what |
| Common action registry | `ActionRegistry` (what fits), `ActionCatalog` (what it may do) | QR Code, Create ZIP, `keepAndAct` |
| Common workflow execution | `ActionRun` (tokens, progress, cancel) + `ActionExecutor` | `ActionChain`, `ChainProgress`, `ChainArtifacts`, `ActionRun.advance` |
| Common activity reporting | `ActivityEvent` into the queue | Chains publish running / completed / failed / cancelled |
| Common intent ranking | `IntentEngine` | Next Action rules are deterministic and offered, never run |
| Common privacy enforcement | `ActionGuard` before every run | Every chain step is checked before the chain starts |

## Contributor areas

Each is independent of the others and has a clear contract.

| Area | Problem | Where | Contract | Done when |
|---|---|---|---|---|
| Chain presets | Useful multi-step defaults | `ActionChain.presets` | Steps must fit (`output(from:)`), only `createsFile` steps | A test in `ActionChainTests` proves it fits; acceptance check runs it |
| WebP output | Smaller web images | `ActionExecutor.image` | New `ContentAction`, `createsFile`, only if `CGImageDestinationCopyTypeIdentifiers` lists WebP | Unit test for the registry; real file written in QA |
| Color palette | Keep and reuse colors | `ClipEntities.ColorValue`, a new shelf kind | Memory or SwiftData, clearable, listed in `PrivacyCatalog` | Settings entry and tests |
| Context detectors | More signals for work modes | `ModeRules` | Signals NotchFlow already has; a `ModeDetector` switch each | `WorkModeTests` |
| Agent Rescue sources | More failures worth a brief (a failed test step's name, a local build's error count) | `AgentRescue.brief`, the inbox contract | Only fields a tool already reports; nothing fetched; secrets left out | `AgentRescueTests` |
| Accessibility | VoiceOver and keyboard for glances | `SuggestionGlance`, `ActionsSurface` | No layout changes to size contracts | A VoiceOver pass recorded |

These aren't "good first issues": each touches a shared contract and needs the tests named.
