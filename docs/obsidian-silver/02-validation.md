# Obsidian & Silver: validation

Evidence from the development Mac (MacBook Air, built-in notch, dark menu bar), 2026-10-20/21. Captures
cover a 600 × 460 pt region centred on the notch (`screencapture -R`); recordings are ~30 fps and inspected
frame by frame. An offline renderer draws `NotchShape` itself on a **light** menu bar at up to 8×, because the
development Mac's dark menu bar hides the shoulder joint.

Status: **Verified** (seen on screen or in recorded frames), **Partial** (seen before the palette pass,
or only offscreen), or **Pending** (needs a real interaction or a recording). The display slept partway
through Phase 4; the on-screen pass below was run after it woke.

| # | Brief §14 check | Status | Evidence |
|---|---|---|---|
| 1 | Resting notch | Verified | Rest capture; offline render shows the shape 1 pt inside the hardware outline |
| 2 | Idle → Hover | Verified | Hover capture and 8× render: the notch stretches 8 pt sideways and 5 pt down; silver light at the lower corners |
| 3 | Hover → Compact | Verified | Frames: grows downward from the notch, content condenses in, sharp at ≈240 ms |
| 4 | Compact → Expanded workspace | Verified | Frames: continuous growth; silhouette full size by ≈400 ms, staggered content reveal complete ≈440 ms. On screen: an agent card opens into Recent (6 steps) beside Session (project, branch, repository, app, started) |
| 5 | Expanded → Idle | Verified | Frames: content leaves first, silhouette retracts into the notch |
| 6 | Music opening and closing | Partial | On screen: the player opens black and silver (no player was running, so the scrubber and artwork travel aren't exercised yet) |
| 7 | File approaching the notch | Pending | Needs a real drag (can't be scripted without Accessibility) |
| 8 | File entering the shelf | Pending | Same |
| 9 | Multiple activities stacking | Verified | On screen: six rows; amber only for waiting on you, red only on failure glyphs, running work silver |
| 10 | Failure notification opening | Verified | On screen: the lower edge lights red briefly; red stays on the glyph, and the action is the blue primary |
| 11 | Tools opening | Partial | On screen: the launcher's native-style monochrome glyphs; the tile-to-panel morph isn't recorded yet |
| 12 | Rapid mid-animation switching | Verified | Glance → workspace → close within 270 ms: continuous, no snap, no blank frame |

Specific rejection criteria from brief §12:

| Criterion | Result |
|---|---|
| Card floating below the notch / shadow separating them | Not present: one clip shape, no window or inner shadow |
| Bright horizontal outline across the top | Not present: edge and rim light are masked off the band |
| Notch unchanged while an unrelated rectangle appears | Not present: every state is the same shape resized |
| Dropdown slide or fade-in card | Not present: growth starts at the notch's own size |
| Giant window with unused space | The panel trims to the silhouette after each transition (checked by window size readouts) |
| Visible window relocation | The panel frame is never animated; the drawing stays anchored to the notch |

## Manual checks (to run on hardware)

1. Turn on a light menu bar (a light wallpaper with "Reduce transparency" off). Hover the notch, then open
   the workspace. Look for any seam or step at the shoulders and at the bottom of the camera housing.
2. Start a Claude Code session with the hooks from Settings › Agents. Open its card: Recent should list
   tool steps, Session should show project, branch, repository and app.
3. Play a track in Music. Open Music in the workspace and drag the scrubber; release seeks.
4. Drag a file from Finder toward the notch: the bottom edge stretches with a silver highlight, then
   becomes a drop target. Drop it and check the shelf count.
5. Toggle System Settings › Accessibility › Display › Reduce motion and repeat 1: transitions become short
   fades with no overshoot.
6. Connect an external display and choose it in Settings: the surface anchors at that display's top centre
   (a simulated notch).

## Known open items

- Footprint grew 26 → 52 MB over a 30-minute idle run in which the workspace was opened. It hasn't yet
  been investigated whether that is cached views or a leak.
- Full expansion: the silhouette lands inside the 280–420 ms range (≈400 ms); the content reveal finishes ≈40 ms later. Both should be tuned on hardware, as the brief asks.
