# Dynamic hover

Hovering the notch shows what matters most right now, built from real application state. It replaced the
static "Workspace · Click to open".

## Where it lives

| Responsibility | Code |
|---|---|
| Priority policy (ranking, stability, hysteresis, split pairing) | `Sources/NotchCore/HoverPolicy.swift` (tested in `HoverPolicyTests`) |
| Context resolver (candidates from existing providers) | `AppModel.hoverCandidates`, `hoverTier`, `hoverFamily` |
| Presentation model | `AppModel.GlanceLead` (`single`, `split`, `quickAccess`, plus `notification` and `privacy`) and the stored `hoverChoice` |
| Views | `GlanceView`, `SplitRegion`, `QuickAccessRow`, `HoverItemLabel`, `HoverItemTrailing` in `Shell/OverlayView.swift` |
| Sizing | `SurfaceLayout.form(.preview)`: quick access, single and split each have a fixed size, never measured from text |
| Interaction | the existing hover intent, 0.3 s leave grace and 10 pt slop in `WindowManager`; `AppModel.lockHover` while a control is used |

No new activity manager: candidates come from the activity queue, `MediaService` and the countdown.

## What it shows

| State | Preview | Click opens |
|---|---|---|
| Nothing live | Music · Shelf · Tools shortcuts | That feature |
| Agent working | Claude Code / *project · Running Bash · 12m* | That session |
| Agent needs input | **Input required** / *Claude Code needs your approval · project*, amber dot | The request in its card |
| Music playing | Artwork, title / *artist · Playing*, play-pause | Music (the control only toggles playback) |
| Build or CI running | **Build in progress** / *title · branch*, spinner or a real percentage | That activity |
| Build or CI failed | **CI failed** / *title · branch*, red mark | That activity |
| Focus timer | **Focus session** / *18:42 remaining* (live), pause-resume | Tools › Timer |
| Several things | The top one, then **+N** | The item, or the whole stack from +N |
| Ambient + work | Split: music or timer on the left, the work on the right, one surface with a hairline between | Each side its own destination |

Every line comes from the record, the player or the timer. Agents never get an invented task summary,
because the hooks don't send one, so the preview shows the project and the current tool instead.

## Priority

1. Input needed: an agent or workflow waiting on you.
2. Failures.
3. Pinned items.
4. Something imminent: a running focus timer, or a call about to start.
5. Running work in a category boosted by the app in front.
6. Running agents and builds.
7. Music that's playing.
8. Anything else live (downloads, a paused timer).
9. Quick access.

Within a tier the newest wins, then the id.

Stability rules:
- **Stays put:** what's shown stays while it still exists and nothing more important arrives, so equals
  never reshuffle.
- **While hovered:** only input or failures may replace it.
- **During control use:** pressing play, pause or Join holds the selection for 2 s.
- **Stale or finished items:** these are never shown. They leave the queue's live set, so the next
  refresh replaces them.
- **Refresh triggers:** state changes (ingest, media, timer, context, expiry) and the start of a hover.
  Nothing polls.

## Split island

Split mode is used only when one side is **ambient** (music or a running timer) and the other is work
that matters: input, a failure, something pinned or imminent, or running work. Two activities get a count
instead. A download beside music isn't worth a split. Split needs `notch + 300` pt of display width;
narrower displays get the single preview. Each region has its own click target and its own hover
highlight, and moving between regions doesn't move the surface.

## Motion

The hover opens with the existing surface spring (compact range, ≈220 ms) and the reveal order (icon,
title, detail, controls). When the shown item changes, the outer surface stays and only resizes if the
layout needs it. The old item lifts out and the new one settles in from just below, inside the mask.
Single ↔ split widens or narrows the same surface. Reduce Motion turns these into short fades.

## Verified (2026-10-21)

- **Unit tests:** 8 `HoverPolicyTests` cover tier order, no reshuffle between equals, hover-only-critical,
  the control lock, disappearance, split pairing, the narrow fallback and the count.
- **On screen (neutral stage):** every state above, including both split pairings and +2 with stacked
  layers.
- **Recorded:** music, then an arriving request widens into the split, then the session ends and it
  condenses back to music. One continuous surface with no close and reopen.
- **Click routing:** checked through the same handlers the buttons call (a debug verb). The split's work
  side opens that exact request, the ambient side opens Music, +N opens the stack, and the timer opens
  Tools › Timer. Real pointer clicks weren't scripted, so the user's cursor wasn't taken over.
