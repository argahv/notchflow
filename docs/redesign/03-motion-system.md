# 03 · Motion system

Every animation comes from `Design/Motion.swift`. Motion explains state, origin and continuity; nothing loops at rest.

## Presets

| Preset | Curve | Use |
| --- | --- | --- |
| `micro` | spring 0.18 / 0.9 (≈90–160 ms) | Hover, press, small indicators |
| `quick` | spring 0.26 / 0.9 (≈150–220 ms) | Toggles, content-driven resizes, glance subject swaps |
| `fluid(opening: true)` | spring 0.40 / 0.84 | The surface opening or growing; a hint of give |
| `fluid(opening: false)` | spring 0.30 / 1.0 | Closing or shrinking; faster, no overshoot |
| `expressive` | spring 0.48 / 0.72 | A dropped file landing |
| `selection` | spring 0.30 / 0.86 | Sliding selection indicators |

Ambient motion is limited to the playing-music waveform (SF Symbol variable colour, active only while playing) and a one-shot bounce when a band status changes. Both stop under Reduce Motion.

## Reveal and collapse hierarchy

1. The silhouette deforms immediately (one transaction with the state change).
2. Primary content condenses in at 20 ms: opacity 0 → 1, blur 6 → 0, scale 0.97 → 1, offset −5 → 0.
3. Secondary controls at 90 ms (dock items stagger 22 ms apart).
4. Detail and actions at 150 ms.

The reveal is state-driven (`.reveal(_:)` animates on appear) because SwiftUI runs only the outermost inserted view's transition. On the way out the content layer fades in 150 ms while the silhouette retracts over ≈300 ms, so information compresses first and the material retracts last. The outgoing fade outlasts the incoming reveal's delay, so a feature switch never shows an empty frame.

## Shared elements

One namespace spans the surface (`nookNamespace`).

| Element | Travels between |
| --- | --- |
| `lead-<activity>` | Resting status dot → glance glyph → activity capsule glyph |
| `music-art` | Band artwork/waveform → glance artwork → player artwork |
| `timer-glyph` | Glance timer → activity timer strip |
| `tile-<tool>`, `tile-icon-<tool>`, `tile-title-<tool>` | Launcher tile → tool panel background, header icon, header title |
| `note-<id>` | Note card → editor |
| `dock-selection` | Between dock items |
| command selection | Between command rows |

## Interruption

The panel only ever grows before a transition and trims after the *latest* one settles (a transition token discards stale completions), so reversing mid-flight never clips. SwiftUI springs retarget from their presented value and keep velocity. Interaction stays live during transitions; only the panel's hit area is briefly larger than the drawing.

## Reduce Motion

`Motion.reduced` follows macOS Reduce Motion, or the `NotchFlowReduceMotion` default (lets the path be verified without changing a system setting). Every preset becomes a 100–160 ms ease-out with no overshoot; reveals become opacity-only with half the delay; the silhouette still resizes, but quickly and without give; ambient effects stop. Functionally nothing changes.

## Measured (screen recordings, ≈30 fps, this Mac)

| Transition | Result |
| --- | --- |
| Resting → workspace (previous pass; same panel strategy, spring 0.42 / 0.84) | Centred on the notch every frame; at full size ≈230 ms, settled ≈270 ms |
| Workspace → resting (previous pass) | Content gone by ≈100 ms; silhouette back at the notch by ≈400 ms; no clipping when the panel trims |
| Glance → workspace | Glance row's glyph holds position into the first capsule; content sharp by ≈266 ms; dock in by ≈466 ms |
| Music → Activity, 150 ms into opening | Continues from the current size; no jump to Music's final geometry, no blank frame; settled ≈200 ms later |
| Tools tile → Notes | Icon and title travel into the header (title no longer truncates mid-flight); settled ≈100 ms |
| 10 rapid hover cycles | Ends at rest, panel trimmed to 324 × 38 |

These are visual checks from recordings, not Instruments frame-time measurements.
