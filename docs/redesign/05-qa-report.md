# 05 · QA report

Run 2026-10-20 on macOS 27.0 (26A428), Xcode 27.1, Mac17,3, one notched 1710 × 1112 pt display. Evidence comes from builds, test runs, the window list (`CGWindowListCopyWindowInfo`), screen recordings stepped at ≈30 fps, and `top` / `footprint`. Scripted runs used the Debug-only command channel (see 02); where a scenario needs a physical pointer, drag or display change, that is stated.

## Build and tests

| Check | Result |
| --- | --- |
| Debug build | Succeeds. 13 unique warnings (baseline 18), all pre-existing Swift-concurrency diagnostics in `CalendarService`, `SystemServices`, `BackdropService`; none from redesign code |
| `swift test` | 23 / 23 pass (9 original + 14 new: attention priority, preemption, de-duplication, throttling, editing suppression, capacity; geometry band, wings, clamps, jitter; awareness; contradictory events; history retention) |
| Python bridge tests | 9 / 9 pass |
| Shader | Compiles and its pipeline builds via the Metal runtime compiler (the app's path). Offline `metal` compiler not installed here, so the CI shader step was not run |

## Acceptance scenarios

| | Scenario | How | Result |
| --- | --- | --- | --- |
| A | Rapid enter/leave ×10 | Debug channel driving the hover-intent and leave paths, 300 ms cycles | **Pass (simulated).** Ends at rest; panel trimmed to 324 × 38; no stuck state. The physical tracking area was not driven |
| B | Open Music, switch to Activity mid-transition | Recording, switch at 150 ms | **Pass.** Continues from the current size, no jump to Music's geometry, no blank frame |
| C | Tools with no notes | Contract and view built; on screen the list showed one existing note (kept, not deleted) | **Partial.** Empty state is one 58 pt row with *New note*; not seen with zero notes |
| D | Create a note, type paragraphs, close | `note:new` → editor appears from its card, focus moves in after the morph; an empty note is discarded on close | **Partial.** Typing several paragraphs was not run (would have typed during a live call on this Mac) |
| E | Drag a file toward the notch, leave, re-enter | — | **Not run.** Needs a physical drag. Code: passive drag monitor → drop target; `draggingEntered/Exited/performDrop` |
| F | Notification while editing a note | Recording | **Pass.** Coral rim only; editor and caret untouched; the failure replays as a glance after the note closes |
| G | Failure notification | Recording | **Pass.** Coral capsule (glyph, title, source, *View*, ✕); *View* opens the detail with *Return to task* / *Remove*; dismiss works; kept in History |
| H | Disconnect a display mid-expansion | — | **Not run.** One display. Code: `didChangeScreenParameters` re-measures and places the panel immediately |
| I | Reduce Motion | `NotchFlowReduceMotion` app default (system setting not changed) | **Pass.** Opens and closes without blur, scale or overshoot; fully functional |
| J | Idle 30 minutes | `top` every 10 s, `footprint` at start and end | See below |

## Idle (scenario J)

A 30-minute measurement was still running when this report was first committed; results follow in a later revision. Baseline before the redesign: 0.0–0.3 % CPU (mean ≈ 0.1 %) over 60 s, 36 MB footprint (see 00).

## Defects found by QA and fixed

1. The Debug command channel never compiled: the project generator did not define `DEBUG`. Fixed in `Scripts/generate_project.py`.
2. After a collapse the panel could stay at its expanded size (468 × 186 over a resting drawing) when the animation completion was held back. Added a timed trim fallback.
3. Dock controls at the band's outer edges were clipped by the ears (content 150 pt in a 130 pt wing). Wings now 146 pt with 26 pt controls.
4. A tool title truncated ("Not…") while travelling from its tile. Fixed by self-sizing the shared text.
5. The Music error row was cut off when the error appeared after the surface had been sized. Errors now reflow the surface.
6. Spotify's raw AppleScript error was shown verbatim. Now recovery guidance.
7. The geometry engine let a contract's minimum width beat the screen edge on narrow displays (caught by a unit test).
8. A near-blank frame between feature swaps. Fades now overlap.
9. The tile → tool morph was barely visible. The icon and title now travel into the header and the panel background is visible.
10. Nested reveal transitions never fired (SwiftUI runs only the outermost inserted transition). Reveal is now state-driven.

## Not verified

- VoiceOver walk-through, Tab-order audit, large text sizes.
- Multiple displays, negative origins in practice, scaling modes, Spaces / fullscreen apps, Stage Manager, menu-bar auto-hide, sleep/wake.
- Ultra mode on screen (needs Screen Recording permission, not granted).
- Calendar and Reminders granted states, Mirror with the camera on, Music with permission granted.
- Instruments (Time Profiler, Core Animation, Allocations, Leaks, Metal System Trace, Energy Log).

## Known gaps against the brief

- No smooth SDF shape merging (see 04).
- Notes search exists; arrow-key navigation between notes does not. History groups by day, not by session.
- Size negotiation uses data-driven contracts per route rather than a per-view protocol; this is deliberate to avoid measuring views (02).

## Manual verification steps

1. **Hover (A):** move the pointer onto the notch and away ten times quickly. Expect a glance that comes and goes, never stuck, and nothing blocking the menu bar afterwards.
2. **Drag (E):** drag a Finder file toward the notch. At ~1–2 cm it becomes "Drop to shelf"; enter, leave, re-enter, drop. Expect one shelf item, a mint flash, and an automatic return if the shelf was opened by the drag.
3. **Notes (C/D):** with no notes, open Tools → Notes: one row with *New note*. Create a note, type several paragraphs, use undo and an input method (e.g. Japanese). The editor grows two lines at a time to a ceiling, then scrolls; nothing is lost on close.
4. **Displays (H):** with an external display, start opening the workspace and unplug it. The overlay should reappear on the remaining display, interactive.
5. **System settings:** turn on Reduce Motion, Reduce Transparency and Increase Contrast; check VoiceOver reads the dock, glance and rows meaningfully.
