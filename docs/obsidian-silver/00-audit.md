# Obsidian & Silver: Phase 1 audit

Branch `feat/obsidian-silver`, from `feat/liquid-workspace-2` (2026-10-20). Inputs: the code, plus
window-only captures and recordings from the 2.0 and earlier passes on the development Mac (MacBook Air,
built-in notch).

## Where the brief's responsibilities already live

The brief names six coordinators. Each has an existing home, so this redesign refactors in place and adds no
parallel managers.

| Brief | Existing code | Gap |
|---|---|---|
| NotchGeometryEngine | `DisplayGeometry` (NotchCore), `WindowManager.updateGeometry`, `SurfaceGeometryEngine` (size contracts) | Anchors on the **screen** midpoint, not the measured notch; the hardware notch's corner radius isn't modelled |
| NotchSurface | `NotchShape` + the single `clipShape` in `OverlayView` | Shoulders are quadratic curves (a curvature break at the joint); radii step 2 → 6 → 10 pt between states |
| NotchMotionCoordinator | `AppModel.commit` (one animated transaction, grow-then-trim panel), `Motion`, `nookNamespace`, `Reveal` | Timings sit at the long end of the brief's ranges; sound overall |
| NotchPresentationController | `InteractionState` (NotchCore), `Route`, `SurfaceLayout` | Expanded state always shows a 7-item dock |
| NotchMaterialRenderer | `ObsidianSurface`, `EdgeLight`, `RimIllumination`, `GlassSurface` + `LiquidGlass.metal`, `BackdropService` | Balanced mode lightens toward the bottom; violet accents |
| NotchInteractionCoordinator | `WindowManager` (passive monitors, hover intent, drag approach, outside click), `AppModel` hover/dismiss, hot key | Fine; keep |

The panel itself is already an invisible container: borderless, non-activating, transparent,
`hasShadow = false`, at `.statusBar`. Its frame is never animated; it grows before a transition and trims
after, so it never blocks the screen once settled.

## Why the surface can read as detached

1. **Tonal step under the notch.** In Balanced mode the expanded area is `.hudWindow` material + obsidian
   at 0.86 + a gradient up to `surface` at 0.55, while the band is pure black with a 34 pt fade. The result
   is a lighter grey slab starting just below the camera housing: a card under the notch, not the notch
   growing.
2. **Shoulder joint.** Quadratic ears meet the vertical sides with a curvature discontinuity, and their
   radius changes by state (2, 6, 10 pt). During motion that shows as a small kink, or a "shoulder", where
   the brief asks the material to flow outward.
3. **Resting width.** By default the resting notch carries a permanent battery label, so it sits 58 pt wider
   on each side than the hardware all day. The brief wants rest to be nearly indistinguishable from the
   notch.
4. **Anchor.** The surface centres on the screen. On current MacBooks the notch is centred within a point,
   but the measured edges (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`) are the source of truth the
   brief asks for. Simulated notches have no edges to measure and keep the screen midpoint.
5. **Accent and chrome.** Violet (`Ink.iris`, 33 uses) marks selection, tool icons, pins and the timer.
   Expanded views always show the dock as a navigation bar, and inner cards use lifted fills with strokes and
   shadows, which reads as a dashboard.

## Plan, following the brief's phases

| Phase | Work |
|---|---|
| 2 Silhouette | Measured notch centre and corner radius in `DisplayGeometry`; a continuous-curvature `NotchShape` (cubic shoulders and corners, one parameter set that interpolates from the hardware notch out to the workspace); a resting state that matches the hardware notch exactly when there's nothing to show; deep-black material with no lightening; silver edge light only on the lower edge, brighter while the shape is moving |
| 3 Motion | Presets inside the brief's ranges (hover 100–160 ms, compact 180–260, full 280–420, collapse 220–350, buttons 90–150); interruption keeps velocity (SwiftUI springs retarget); compact content morphs into the expanded layout through the shared namespace |
| 4 Core UI | Obsidian & Silver tokens (Physical Black, Obsidian, Carbon, Graphite, Titanium, Silver, Ice White, Muted Silver; system blue, green, amber, red as semantics only); resting indicators kept to one; agent compact and expanded workspace (recent steps in memory from hook events, session metadata; two columns only when wide enough); notch-native music; magnetic shelf; notifications that emerge from the edge |
| 5 Remaining | Contextual action row instead of the permanent dock, compact tool launcher, clipboard, calendar, notes, history, command palette, all on the same surface |
| 6 Material | Restrained reflections that catch light in motion and settle; optional Metal refinement only where it improves continuity |
| 7 Validation | Frame-by-frame recordings of the 12 transitions in brief §14; idle cost; Reduce Motion; multiple displays |

## Constraints carried forward

All 2.0 behaviour stays: the activity engine, agent hooks and approvals, GitHub, downloads, clipboard,
meetings, context and modes, and their privacy rules. Agent "recent actions" use only what the hooks already
publish (state and tool names). No prompts, inputs or file paths are added, so a "changed files" column
isn't available and won't be faked. The right column shows session metadata instead.
