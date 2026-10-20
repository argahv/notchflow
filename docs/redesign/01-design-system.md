# 01 · Design system — Obsidian Liquid

Source of truth: `Sources/NotchFlow/Design/` (`Tokens.swift`, `Materials.swift`, `Controls.swift`, `Motion.swift`) and the layout constants in `Shell/SurfaceLayout.swift` (`Metrics`). Feature views use these; raw colour or spacing literals in a surface are a defect.

## Colour

Colour is functional. One accent at a time; state colours appear only where they carry meaning.

| Token | Hex | Role |
| --- | --- | --- |
| `Ink.void` | #08090D | Performance surface, deepest layer |
| `Ink.obsidian` | #0D0F14 | Glass tint, ambient cards |
| `Ink.surface` | #15171E | Interactive cards at rest |
| `Ink.elevated` | #1D2029 | Hovered / expanded cards, secondary pills |
| `Ink.hover` | #282B36 | Icon-button hover disc, rails |
| `Ink.primary` | #F2F2F7 | Text |
| `Ink.secondary` | #A0A3B1 | Metadata. ≈7:1 on `surface`; the floor for any readable text |
| `Ink.muted` | #707481 | Glyphs and inactive chrome only (≈4:1, below body-text contrast) |
| `Ink.disabled` | #555965 | Disabled labels |
| `Ink.iris` | #A99BFF | Interaction and selection: dock selection, tiles, primary pills, focus ring |
| `Ink.mint` | #73E0BD | Success, completed, live (camera on, file landed) |
| `Ink.amber` | #FFBE76 | Waiting / action required, adapter warnings |
| `Ink.coral` | #FF858F | Genuine failure only |
| `Ink.blue` | #82B8FF | In-progress information |

`Tone` maps these to state: `ActivityPhase.tone` (waiting → amber, failed → coral, completed → mint, started/progress → blue, cancelled → neutral) and `AttentionPriority.tone`.

## Materials

| Level | Implementation | Used for |
| --- | --- | --- |
| 0 · Physical notch | `ObsidianSurface` band: pure black through the menu-bar band, feathering 34 pt into the glass | The top of every state; with no status the resting surface sits entirely behind the camera housing |
| 1 · Ambient glass | `nookMaterial(.ambient)`: obsidian 80 %, 3.5 % top highlight | Empty states, timer strip |
| 2 · Interactive glass | `nookMaterial(.interactive)`: surface → elevated on hover, top-lit hairline 5.5 → 10 % | Rows, tiles, fields, file tiles |
| 3 · Elevated glass | `nookMaterial(.elevated)`: elevated fill, 12 % highlight, 12 pt / y 6 shadow | An expanded activity card |
| 4 · Transient illumination | `RimIllumination`: tone-coloured rim + soft radial wash, keyframed 0 → 1 (140 ms) → 0.6 → 0 (≈1.3 s total) | New notification, attention while busy, file landed |

The main silhouette's resting `EdgeLight` lights the lower edge only; the sides fade out before the band and the top (the bezel) never lights. Approach awareness swaps in a restrained iris rim. Balanced = `NSVisualEffectView` (.hudWindow) + obsidian 86 % + a slight lift toward the bottom; Performance and Reduce Transparency = solid `Ink.void`; Ultra adds the Metal layer (see 04).

## Type

SF Pro throughout (`TypeScale`). Section title 18 semibold (header titles inside tools use 15 to stay compact); card title 13 semibold; body 13; secondary 11.5; meta 11 medium; badge 10.5 semibold; large timer 28 rounded medium; numerals 11.5 semibold. Timers, battery, percentages, playback times and elapsed labels use monospaced digits.

## Space, radii, shape

Spacing scale 4 / 8 / 12 / 16 / 20 / 24 / 32 (`Space`); surfaces pad 14, stack gap 8 (`Metrics`). Radii: controls 9, cards 14, capsule 22, workspace 28 (`Radius`).

`NotchShape` is the one silhouette: full-width top, concave ears where it meets the bezel, convex bottom corners. Ears and corners are animatable, so the outline never jumps from sharp to round:

| State | Ear | Bottom corner |
| --- | --- | --- |
| Resting, nothing to show | 2 | 9 |
| Resting with status / approach | 6 | 12 |
| Drop target, glance | 10 | 20–22 |
| Workspace | 14 | 28 |

## Controls

All in `Controls.swift`; each has rest, hover, pressed and disabled states and animates them with `Motion.micro`.

- `IconButtonStyle` — glyph on a hover disc; press scales to 0.9.
- `PillButtonStyle` — text actions; `prominent` carries a surface's single primary action in a tone colour.
- `RowButtonStyle` — whole-row target on interactive glass.
- `DockButtonStyle` — feature glyphs in the band; the iris selection capsule is a shared element that slides between items; an optional state badge.
- `ToneGlyph` — status/category glyph on a disc of its own tone.
- `CompactEmptyState` — one row, one clear action. Empty states never occupy a large blank panel.
- `ProgressLine` — determinate only. Running work without a real fraction shows a spinner, never an invented percentage.

## Iconography

SF Symbols only. Event publishers get a glyph from their source name by whole-word match (`SourceGlyph`): agent → sparkles, deploy → shippingbox, test → checklist, build/ci → hammer, timer → timer, terminal → terminal, otherwise bolt. Quick apps show the application's real icon from `NSWorkspace`; shelf files show QuickLook thumbnails, falling back to the Finder icon.

## Accessibility variants

- Reduce Motion (system, or the `NotchFlowReduceMotion` default for verification): every preset becomes a short ease-out with no overshoot; reveals are opacity-only; the attention bounce and the playing waveform stop.
- Reduce Transparency: solid surface, no capture.
- Focus: native focus rings stay on controls; the band's whole-width toggle target disables its ring (it drew a stray line under the notch). Every glyph-only button has an accessibility label and a `.help` tooltip naming its shortcut.
