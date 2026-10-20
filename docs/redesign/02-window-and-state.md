# 02 · Window, state and geometry

## Window strategy

One long-lived `NotchPanel` (borderless, non-activating, status-bar level, all Spaces, fullscreen auxiliary). The SwiftUI root sits in a plain container view rather than being the panel's content view — as the content view `NSHostingView` re-requests constraint passes during frame changes until AppKit throws (the original build's crash).

**Chosen: a panel that always covers the drawn silhouette.** The frame is never animated:

1. Before a transition, `WindowManager.prepare(for:)` grows the panel to the union of the current and next silhouette. The drawing stays centred on the notch, so the resize is invisible.
2. One SwiftUI transaction animates the silhouette and its content.
3. `settle(_:)` trims the panel to the final silhouette on the animation's completion, with a 0.9 s timed fallback because completions can be held back while the window isn't drawn (Mission Control, occlusion).

| | Dynamic panel (chosen) | Oversized transparent panel |
| --- | --- | --- |
| Input outside the visible surface | Blocked only during a ≤ 0.9 s transition window | Depends on WindowServer alpha hit-testing; risks a permanent dead zone over the menu bar |
| Menu-bar items beside the notch | Reachable whenever the surface is at rest | At risk |
| Animation | SwiftUI owns the whole morph; no AppKit frame animation | Same, no resizes |
| Cost | A frame set at the start and end of a transition | None |

Display changes (`didChangeScreenParameters`), including mid-transition, re-measure the display, recompute the form and place the panel immediately. Display origins may be negative; `DisplayGeometry.origin` is tested for that.

## State model

- **`InteractionState`** (NotchCore, tested): `presentation` (collapsed / preview / expanded), `pinned`, `dragging`, `editing`, and `awareness` (none / pointer / drag). Explicit events: enter, leave, expand, dismiss, togglePin, begin/endDrag, begin/endEditing, attention, approach, dragApproach, retreat.
- **`Route`**: feature plus sub-route — `activity(detail:)`, `music`, `shelf`, `tools(Tool?)`, `history(detail:)`, `command`. Sub-routes stay inside their feature's view; per-feature route memory restores where you were.
- **`PresentationSnapshot`** = interaction + route + open note. It fully determines geometry.
- **`AppModel.commit(_:)`** is the single path to any visual change: compute the next `SurfaceForm` from the snapshot and data, grow the panel, apply everything in one animated transaction, trim afterwards. `send`, `navigate`, `open`, `back` and `reflow` all go through it. Springs retarget from their current value, so an interrupted transition reverses from where it is.

## Adaptive size engine

Surfaces declare a `SizeContract` (minimum / preferred / maximum, heights below the band) computed from **data** — row counts, states — never from measured views, so window size can't feed back into SwiftUI layout. Views fix the row heights the contracts assume (`Metrics`). `SurfaceGeometryEngine.resolve` (NotchCore, tested):

- adds the band; keeps room beside the notch for the band controls (`notch + 2 × wing`);
- clamps to the display (16 pt margins, 70 pt bottom clearance); the screen edge always beats a contract's minimum;
- snaps to whole points and ignores changes under 2 pt.

Examples on a 1710 × 1112 pt notched display — observed in the window list: resting with status 324 × 38, glance 444 × 102; computed from the contracts: resting with nothing to show 208 × 38 (hidden behind the housing), empty Notes 500 × 162, Tools launcher 500 × 210. Expanded activity grows per row to a 420 pt content ceiling, then scrolls.

Content that changes size (a to-do added, a note growing two lines, an error appearing) calls `reflow()`. The note editor resizes only after a 450 ms typing pause, in two-line steps, so selection, undo and IME composition are never disturbed.

## Attention

`AttentionCenter` (NotchCore, tested) decides whether an event may present itself:

| Phase | Priority | Behaviour |
| --- | --- | --- |
| failed | critical | Preempts a lesser glance; coral rim; 9 s |
| waiting | actionRequired | Glance; amber rim; 7 s |
| completed | informational | Glance; mint rim; 4 s |
| started / progress | background | No glance; band status only |
| cancelled | silent | Nothing |

Rules: the same task refreshes in place instead of stacking; equal or lower priority queues; non-critical interruptions are throttled to one per 3 s; while editing or with the workspace open nothing opens — the rim lights and the Activity dock item gets a badge — and items still worth showing replay when the person finishes (stale informational ones are dropped); quiet mode and privacy only light the rim. Auto-dismiss waits while the pointer is over the glance. Notifications never take keyboard focus.

Resulting priority order (brief Part 10.4): direct interaction (editing, explicit navigation) → active file drag → pinned workspace → critical notification → contextual activity → hover glance → idle.

## Input

- **Hover:** configurable intent delay (default 120 ms) before the glance; exit waits 300 ms and counts 10 pt beyond the edge as inside (hysteresis), so moving toward a control at the rim doesn't collapse it.
- **Approach:** a passive global mouse-moved monitor (no Accessibility permission, nothing intercepted) lights the rim when the pointer comes within ~40–56 pt of the notch.
- **Drag:** a passive left-mouse-dragged monitor reads only the drag pasteboard's *type list*; a file drag within ~120–150 pt turns the resting notch into a drop target large enough to receive it.
- **Keyboard:** ⌃⌥Space toggles; Esc goes back one level, then closes (passes through while an input method is composing); ⌘1–⌘5 features; ⌘K commands with ↑/↓/Return.
- **Scroll:** only a deliberate, non-momentum pull opens the resting notch; inside the workspace scrolling belongs to the content.

## Debug automation (Debug builds only)

`DebugChannel` watches `~/Library/Application Support/NotchFlow/debug` for `*.cmd` files (e.g. `open:tools.notes`, `event:enter`, `reduceMotion:on`) — the same directory-watch transport as the activity inbox. The generator now defines `DEBUG` for Debug builds; it previously did not, so `#if DEBUG` code never compiled.
