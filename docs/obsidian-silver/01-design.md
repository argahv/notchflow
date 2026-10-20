# Obsidian & Silver: design as built

The physical notch is the origin of every interaction. Every state is the same silhouette at a different
size, and nothing appears as a separate card.

## Geometry (NotchGeometryEngine → `DisplayGeometry`, `WindowManager.synchronize`)

- Anchor: the measured notch centre, which is the gap between `auxiliaryTopLeftArea` and
  `auxiliaryTopRightArea`. Whichever coordinate reading places those rects on the screen is used, and the
  result is accepted only within 40 pt of the midpoint. A simulated notch uses the midpoint. Surfaces are
  clamped on screen.
- The hardware notch's lower corner radius isn't reported by macOS. It's modelled as 28% of the notch height
  (6–12 pt), giving 10.5 pt on the development MacBook Air.

## Silhouette (NotchSurface → `Design/NotchShape.swift`)

- The top is the screen edge. The lower corners use `UnevenRoundedRectangle(style: .continuous)`, Apple's
  continuous curvature.
- Shoulders: a cubic from the screen edge into each side, with **both control points on the joint**. That
  gives zero curvature where it meets the bezel and the side, so the outline has no kink. It runs 1.7× further
  down the side than along the top, which reads as material stretching outward.
- One parameter set (`ear`, `corner`, `inset`, size) animates everything:

| State | Width | Shoulder | Corner | Inset |
|---|---|---|---|---|
| Rest, nothing to show | hardware notch | 3 | hardware | 1 pt (inside the housing) |
| Hover | notch + 16 | 6 | hardware + 3 | 0 |
| Compact status | notch + 116 | 6 | hardware + 3 | 0 |
| Glance / notification | notch + 236 | 10 | 22 | 0 |
| Workspace | 500 (or notch + 292) | 14 | 28 | 0 |

## Material (NotchMaterialRenderer → `Design/Materials.swift`)

- Interior: Obsidian `#08090B`, near-opaque, with a trace of native blur in Balanced. Performance is fully
  opaque; Ultra adds restrained refraction, darkened heavily.
- The housing (Physical Black) eases into the interior over 44 pt, so there's no tonal step to find.
- Edge light: Silver, on the lower edge only, strongest at the lower corners. It's invisible at rest, 0.2 on
  hover, 0.11 when open, and 0.26 while the shape moves, settling over 0.6 s. Notification rims use the
  event's semantic colour on the lower edge only, never across the top.
- No window shadow, title bar or background: the panel is a transparent `.statusBar` container that grows
  before a transition and trims after.

## Palette (`Design/Tokens.swift`)

Physical Black `#000000`, Obsidian `#08090B`, Carbon `#111317`, Graphite `#202329`, Titanium `#525760`,
Silver `#C8CDD4`, Ice White `#F4F5F7`, Muted Silver `#9298A2`. The semantic colours are system blue
`#0A84FF` (primary or selected action), green `#30D158` (success), amber `#FFB340` (waiting on you) and
red `#FF453A` (genuine failure). Running work is neutral silver. Artwork and app icons keep their own
colours. With every accent removed, the surface still reads correctly.

## Motion (NotchMotionCoordinator → `AppModel.commit`, `Motion.surface`)

| Change | Spring (response / damping) | Brief range |
|---|---|---|
| Hover stretch | 0.15 / 0.92 | 100–160 ms |
| Rest → compact | 0.22 / 0.88 | 180–260 ms |
| → Workspace | 0.34 / 0.86 | 280–420 ms |
| → Rest (collapse) | 0.28 / 1.0 | 220–350 ms |
| Buttons (`micro`) | 0.13 / 0.9 | 90–150 ms |

Springs retarget from the presented value with its velocity, so a change of mind mid-flight continues
instead of snapping. Reduce Motion turns each of these into a 0.16 s ease-out.

## Interaction

- Press: 2% compression on pills, rows and tiles; small icon buttons compress 5%. Hover is a tonal step,
  not a scale. Disabled controls get no hover state.
- Selection is Graphite with a silver hairline. Blue is reserved for the primary action.
- Dock: features beside the camera, with fewer permanent controls. "Keep open" lives in the More menu,
  whose glyph shows a pin while the surface is kept open.
- Tools launcher: native-looking glyphs, with no card until hover.

## Agent workspace

An open Claude Code or Codex card shows **Recent** (state and tool names from hook events, in memory only)
beside **Session** (project, branch, repository, app, started), in two columns when the workspace is at least
480 pt wide. The permission prompt and the actions row follow. There's no "changed files" column, because
the hooks don't forward file paths, so there's nothing honest to show there.
