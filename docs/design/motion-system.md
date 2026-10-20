# Motion system

All motion comes from `Sources/NotchFlow/Design/Motion.swift`. The rules, presets, reveal hierarchy and
interruption model are unchanged from the first pass ([redesign/03-motion-system.md](../redesign/03-motion-system.md),
which keeps the measured timings). This page is the living reference and adds what Liquid Workspace 2.0
introduced.

## Presets

| Preset | Curve | Reduce Motion | Use |
|---|---|---|---|
| `micro` | spring 0.18 / 0.9 | ease-out 0.10 s | Hover, press, small indicators, "Copied" |
| `quick` | spring 0.26 / 0.9 | ease-out 0.14 s | Toggles, filters, row insertion/removal, retraction, scroll-to-detail |
| `fluid(opening:)` | 0.40 / 0.84 opening, 0.30 / 1.0 closing | ease-out 0.16 s | The surface |
| `expressive` | spring 0.48 / 0.72 | ease-out 0.16 s | A dropped file landing |
| `selection` | spring 0.30 / 0.86 | ease-out 0.12 s | Dock selection, filter pill |

Low Power Mode keeps every transition but drops blur passes and ambient loops.

## One commit path

Every visual change goes through `AppModel.commit(_:animation:also:)`: the panel grows (never animated)
before the transaction, state and form change in one animated transaction, and the panel trims after the
latest transition settles (with a 0.9 s fallback). Since 2.0, the form is resolved again **after** the
`also:` side effect, so anything that changes the content (retraction, hide, filter, a new urgent row)
resizes the surface in the same motion. Opening the workspace freezes the stack's order before sizing.

## 2.0 additions

| Moment | Motion |
|---|---|
| Several activities at rest | Up to three overlapping tone dots plus a count; the lead dot is the shared `lead-<id>` element |
| Glance with more work behind it | The next one or two tasks peek out as 3 pt layers tinted by their state; opening grows each layer into its row (`stack-<id>`) |
| Filter change | The pill slides (`selection`); rows enter and leave with `.row`; the surface resizes in the same transaction |
| Task finishes while open | Stays in place 6 s, then retracts (`quick`) while the History dock button pulses once (1.22 → 1 keyframes; none under Reduce Motion) |
| New request while open | The row is inserted at the top (`quick`); other rows slide down |
| Opening a detail | The card grows in place; the scroll view brings it to centre (`quick`) |
| Overflow past the size cap | The stack scrolls under a pinned filter bar; the last 14 pt fade out instead of cutting |
| Permission prompt | "Allow once" arms to "Confirm allow" (`micro` crossfade) and disarms after 4 s |

Nothing new loops at rest. The permission countdown ticks once a second only while a prompt is visible,
the System tool samples every 2 seconds only while open, and elapsed times update twice a minute.

## Verification

Captured with window-only screenshots on the development Mac: band dots, glance layers, open stack, every
filter, hide, retraction resize, request arrival at the top, prompt → allowed, timeout → "Open Terminal",
notification actions. These are visual checks, not Instruments frame timings. The Obsidian & Silver
redesign that follows replaces the surface and motion system and re-measures them.
