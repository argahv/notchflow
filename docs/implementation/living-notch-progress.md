# Living Notch — progress

Branch `feat/living-notch`. Plan and audit: [living-notch-plan.md](living-notch-plan.md).

**Tested** means automated tests cover it, or it ran end to end on the development Mac (a 13-inch
MacBook Air, M5, 1710 × 1112 pt, 208 pt notch). **Unverified** means it was built but not exercised; each item says why.

## Phase 1 — Notch Portal

**What changed.**
- The notch reacts to a drag heading for it, in four stages kept in `InteractionState.portal`:
  *aware* (within about 340 pt: the rim brightens, the silhouette swells, a small inward chevron),
  *attracted* (within about 150 pt: a target naming what's coming and how many), *open* (over the notch:
  a deeper well, "Drop to keep") and *absorbing* or *failed* after the drop. Zones are entered and left
  at different distances (24 pt apart), so a drag resting on an edge doesn't flicker.
- A drop is read by `PortalIntake`: Finder files and folders become references; image data and promised
  files (browsers, Mail, Photos) are received into NotchFlow's own folder; web links and text (with its
  rich version) are stored as they are. The absorption animation starts only after the shelf has stored
  the items: up to three dropped items shrink, rise into the housing and fade; the lower rim gives once;
  a one-line result follows with an Open action, then the notch returns to what it was showing.
- An open workspace still receives drops into the shelf, as before. Settings › Workspace has a switch;
  off, a drop on the notch opens the shelf (the previous behaviour).
- The shelf holds files (by reference), copies, text and links, with size or word count, time added,
  how it arrived, Quick Look, Open, Copy, Show in Finder, Remove, and Clear with one undo. Dragging an
  item out hands over the file, the link (URL and text) or the text (plain and RTF).
- Fixed on the way: a status on one side of the band was drawn behind the camera when the other side
  was empty.

**Reused.** `InteractionState` (extended, not replaced), `SurfaceLayout` and the geometry engine, `Motion`,
`EdgeLight`, `RimIllumination`, the global drag monitor and the panel's drop handlers, `ShelfService` and
its bookmarks and thumbnail cache, the SwiftData `ShelfFile` model (new fields only, all defaulted),
`AttentionCenter`, the debug channel.

**Files.** New: `NotchCore/PortalRules.swift`, `Features/PortalIntake.swift`, `Shell/PortalView.swift`,
`Tests/NotchCoreTests/PortalTests.swift`. Changed: `NotchCore/Interaction.swift`, `AppModel.swift`,
`Models.swift`, `Features/ShelfService.swift`, `Surfaces/ShelfSurface.swift`, `Shell/OverlayView.swift`,
`Shell/SurfaceLayout.swift`, `Design/Motion.swift`, `Window/WindowManager.swift`,
`Window/DebugChannel.swift`, `SettingsView.swift`, `NotchFlowApp.swift`, one existing test.

**Policy for what's kept.** References never copy, move or change the person's file. Copies are made only
when a drop has no file of its own; they live in `~/Library/Application Support/NotchFlow/Shelf/<id>/`
(folders 0700), are capped at 512 MB each and 2 GB in total, and are deleted when their item is removed
and its undo is gone. Anything left behind (an undo still open at quit, an interrupted promise) is swept
at the next launch. Text is capped at 256 KB. The shelf holds 100 items. Folders are referenced, never
copied or measured.

**Tested.**
- 76 Swift tests (16 new: stages, cancel, absorb, promises, open-workspace path, attention during a drag,
  cargo naming, link and text rules, limits, safe names, orphans) and 23 Python tests, all passing.
- Debug and universal Release builds, no new warnings.
- The existing store migrated in place on the development Mac (backed up first): new columns added, the
  existing item read as a reference with its bookmark, notes untouched.
- On a Debug build pointed at a throwaway folder (`NOTCHFLOW_APP_SUPPORT`, Debug only), through the debug
  channel: every stage; cancel; a drop of a PNG, a PDF and a folder (all kept as references with sizes and
  types); the same image again ("Already on your shelf"); text; a link; a missing file (refused, nothing
  added); Clear and Undo; quitting with an undo open, then the copy swept at launch with originals intact.
- The real pasteboard read path, fed from a separate process through a named pasteboard: Finder-style file
  URLs, raw TIFF (saved as a PNG copy in a 0700 folder), a URL item, RTF with plain text, and URL-shaped text.
- Offscreen captures of each stage (`snapshot`), which check layout and colour but not blur.

**Unverified.**
- A real drag session from another app, live on screen, including the absorption animation's timing
  and drag-out to Finder, Messages, Notes, Slack and browser uploads: screen control wasn't granted for
  this run. Whether Finder copies or moves a dragged-out item on the same volume is the first thing to check.
- File promises from Mail and Photos (needs a real drag from those apps).
- Quick Look from the shelf (needs the panel on screen).
- An external display (none attached).

**Privacy and security.** Before a drop only the drag's type list is read, once per drag. File names are
read only when the drag is over the notch. Drags that start in NotchFlow are refused, so nothing is added
twice; a repeated drop callback is ignored by sequence number. Links are kept only for `http` and `https`
with a host and open only in the browser. Names for copies are reduced to one safe path component. Text
dropped on the notch is the person's explicit choice and is stored like a note. No network access.

**Performance.** No timers or polling were added. The drag monitor already existed; it now reads the type
list once per drag rather than on every event, and commits only when a zone changes. Idle, Release builds,
2 minutes each at rest, sampled every 5 s with `Scripts/profile.sh` on the development Mac in normal use:

| Build | Mean CPU | Max CPU | Resident memory |
|---|---|---|---|
| `main` (`f0f7f58`) with the band fix | 0.00 % | 0.0 % | 26.6 MB |
| Phase 1 | 0.00 % | 0.0 % | 27.2 MB |

Two short runs, not a long-session measurement; the 0.6 MB difference is within run-to-run noise.

Commit: `c567ad3` (and `8a0209b` for the band fix).

## Phase 2 — Screenshot Magnet

**What changed.**
- Opt-in (Settings › Screenshots, off by default). NotchFlow watches the folder macOS saves screenshots to
  (the `location` screencapture preference, or the Desktop) with a file-system event source, and reports a
  file only when it is new, recent, an image, and carries the `kMDItemIsScreenCapture` marker that
  `screencapture` writes, so a downloaded or copied image is never mistaken for a screenshot. Each file is
  reported once. If screenshots go to the clipboard or an app, Settings says so instead of watching.
- A screenshot rises out of the notch's lower edge into a compact preview in its own aspect ratio, with its
  pixel size, time and file name, and Copy, Extract Text, Annotate and More (Save to Shelf, Share, Open,
  Show in Finder). The thumbnail opens Quick Look. It leaves after eight seconds, never from under the pointer.
- Extract Text uses Vision on this Mac, off the main thread, with reading order, cancellation, an empty
  state, errors, Copy and Save to Shelf. After three seconds it explains that the first read can be slow.
- Annotate: arrow, rectangle, highlight, text, blur and redact, with undo and redo. Save Copy writes
  "<name> (annotated).png" beside the original (never over anything); Copy puts the image on the clipboard.
  Blur is labelled as not safe for secrets; Redact replaces pixels with black in the saved copy, and is
  applied after blurs so no blur can bring a redacted area back.
- Conflicts: a screenshot waits while a drag, an editor, the workspace or another glance has the surface, and
  appears once it's free if it's still recent. Hidden private details: not shown at all. Quiet mode: the rim
  lights, nothing opens. While its preview is up, passive notifications wait.

**Reused.** The glance and workspace surfaces, routes and size contracts, `BackHeader`, `CompactEmptyState`,
the shelf's intake (Save to Shelf, saving recognised text) and the Quick Look path from Phase 1, the
directory-watch pattern, the debug channel.

**Files.** New: `NotchCore/ScreenshotRules.swift`, `NotchCore/Annotation.swift`,
`Features/ScreenshotService.swift`, `Features/CaptureProcessing.swift`, `Surfaces/CaptureSurface.swift`,
`Tests/NotchCoreTests/ScreenshotTests.swift`. Changed: `AppModel.swift`, `Models.swift`, `Shell/Route.swift`,
`Shell/SurfaceLayout.swift`, `Shell/OverlayView.swift`, `SettingsView.swift`, `Window/DebugChannel.swift`.

**Tested.**
- 83 Swift tests (7 new: candidates, the marker, folder resolution, deduplication, reading order, annotation
  undo and redo, stray clicks) and 23 Python tests, all passing. Debug and Release builds.
- The real watcher on a scratch folder (`NOTCHFLOW_SCREENSHOT_FOLDER`, Debug only): a plain image copied in
  was ignored; a file written the way macOS writes a screenshot (a hidden file, the marker, then a rename)
  was detected and measured (1400 × 800) within about a second; further events on the folder didn't report
  it again.
- Vision on a 1400 × 800 test image: the right text in the right order. The first read on this Mac took
  about 20 seconds while the system prepared the model (also seen in a standalone script: 26.7 s cold,
  0.18 s warm); later reads finished within about a second.
- An annotated copy compared pixel by pixel with the original: the redacted band is solid black, the blurred
  band is softened (text 85 → 221), the arrow is red, everything unmarked is identical, the size is unchanged,
  and the original's bytes are unchanged.
- A screenshot arriving while the workspace was open waited, then appeared when it closed.
- Idle CPU with the watcher on: 0.00 % over 60 s (Debug build). Resident memory 51.6 MB after three text reads
  and two exports; Vision keeps its model loaded once used. Long-session memory isn't measured yet.

**Unverified.**
- A real screenshot taken with ⇧⌘3/⇧⌘4 (the file and marker were reproduced, not produced by
  `screencapture`), the Desktop access prompt when the switch is first turned on, and the five-second
  floating-thumbnail delay: these need the switch turned on in daily use.
- Quick Look, the Share menu and Copy (Copy would replace the clipboard during a scripted run).
- The arrival and annotation on screen rather than offscreen; an external display.

**Privacy and security.** No Screen Recording permission, no key monitoring, no network. Only the screenshot
folder's listing and one extended attribute are read; screenshots are never moved, renamed or deleted.
Thumbnails are in memory only. Text recognition runs on device. Annotated copies get a new name and are
written without overwriting.
