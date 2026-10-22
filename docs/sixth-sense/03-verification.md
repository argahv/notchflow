# Sixth Sense: verification record

Run on 2026-10-22, macOS 27.0 (26A428), Xcode 27.1 (27A9275), Swift 6.4 toolchain, Apple silicon, on
`feature/sixth-sense`.

## Builds and automated tests

| Check | Command | Result |
|---|---|---|
| NotchCore unit tests | `swift test` | **190 passed**, 0 failed (110 before this branch, 80 new) |
| Bridge and hook tests | `python3 -I Tests/test_bridge.py` | 24 passed |
| Generated project is current | `python3 Scripts/generate_project.py && git diff --exit-code NotchFlow.xcodeproj` | Clean |
| Debug build | `xcodebuild … -configuration Debug build` | Succeeded; no new warnings in changed files |
| Universal Release build | `bash Scripts/build.sh` | Succeeded; `lipo -archs`: `x86_64 arm64` |

New test files: `ContextEventTests.swift` (gate, privacy classes, entity detection, color math, JSON
formatting, link cleaning, secret filter), `IntentEngineTests.swift` (every rule's actions and reasons,
every hold reason, cooldowns, dismissal backoff and muting, learning bounds, hourly cap, sensitivity,
reset, no content in stored learning), `ActionCatalogTests.swift` (catalog agrees with the shown effects,
unique ids, nothing destructive, only Fetch Title uses the network, permission and confirmation checks,
surface tiers including the attention hold, which waiting glance goes next, the stuck-alert pitfall,
privacy catalog coverage), `WorkModeTests.swift` (what each signal points to, switching signals off,
Study never inferred, hysteresis, calls switching at once, shortcuts per mode, the mode's tilt on scores),
`FlowGuardianTests.swift` (counting what waited once, pauses, summary wording, needs-input still coming
through, suggestions held during focus, every download rule, a download's privacy class and gate rule, and
what Extract and Actions declare).

## End-to-end in the running app

A Debug build ran with its own bundle id (`com.argahv.notchflow.dev`) and data folder
(`NOTCHFLOW_APP_SUPPORT`), driven through the Debug channel by [`Scripts/qa_suggestions.py`](../../Scripts/qa_suggestions.py).
Copies enter at `ClipboardService.consider`, the same filters a real copy goes through. Activity events
were written to the sandbox inbox as owner-only JSON, as agents and the CLI do. The app in front was
scripted through the same gate as the real observer, and the real pointer was ignored for the run.
**67 of 67 checks passed** across nine scenarios (58 of 58 twice in a row before the chains scenario was added):

- Turning copy suggestions on starts the clipboard source; turning them off stops it.
- A tracked link copied in Xcode is suggested, with Copy Clean Link first; Why? opens and deepens the shape.
- Dismissing closes the glance and is learned; a second link right after is held as cooling down.
- A color is suggested with RGB and HSL and a swatch; a JSON copy replaces it in place.
- Under More, a long passage is suggested; Keep on Shelf adds a shelf item and shows Undo; Undo removes it;
  the acceptance is learned.
- During a drag the suggestion waits and appears once the drag goes away.
- A finished build waits behind a showing suggestion; a CI failure takes the surface from it, and the
  suggestion counts as superseded, not dismissed.
- With Hide private details on, nothing is suggested and the inspector says why, without any copied content.
- Password-manager and secret-looking copies are skipped before the engine sees them.
- Notch Actions (Count Words on dropped text) still run, now through `ActionGuard`.
- A screenshot waits behind a suggestion, then takes the surface; a sound change waits behind the
  screenshot; a deploy failure takes the surface from the screenshot, which comes back after it, ahead of
  the now-stale sound change.
- Two failures in a row and Escape while the first shows: the second is still shown (the stuck-alert fix).
- A new app in front is pending at first and becomes Developer once it holds, with "Xcode is in front".
  Developer offers Activity, Clipboard and Shelf and ranks agents, builds and CI first. A glance at Figma and
  back doesn't flip it.
- Pinning Creative wins over inference and lifts a copied color to 0.83.
- A call in progress switches to Meeting at once, offers Calendar, Notes and Sound, ranks the call first and
  holds a link suggestion; when the call ends the mode settles back to Developer. With following off, it's
  General.
- A finished archive offers Extract and Show in Finder in place of its plain notice, and the inspector says
  "Downloaded an archive" without the file's name. A finished image offers Actions, which opens Notch Actions
  on it, kept by reference. A text file keeps the plain notice.
- During a focus session a finished build waits without a glance, a deploy failure still comes through, and a
  copy suggestion waits; at the end the Mission Complete glance says "1 min · 1 update and 1 suggestion
  waited" with Review.

**A note on running these on a Mac in use.** The sandboxed build draws its panel over the same notch as any
installed NotchFlow, and its observers see the real Mac. In early runs a real click on the panel accepted a
suggestion, and a real browser coming to the front moved the work mode, which both upset the script.
Neither was a defect. Later, real mouse movement closed a scripted drag and kept a suggestion waiting as if
the pointer were over the notch. The Debug channel now lets a script own the app-in-front source (`front:`
until `front:real`) and ignore the real pointer (`pointer:scripted` until `pointer:real`); the script does
both, and the suite has since passed twice in a row on a Mac in use.

Rendered snapshots of the link, Why?, color, JSON, kept-on-shelf and failure states were reviewed. They
showed one real defect (action pills truncated to "Co…" and "O…"), fixed by keeping the controls at their
natural size and giving the glance its own wing. Snapshots come from `ImageRenderer`, which can't draw
AppKit-backed views: the material behind the glance and the borderless More menu render as placeholders
there, as they do for the existing capture glance.

- Action Chains: two real images run through Web-Ready Images; both results reach the shelf, the resized copies
  made in between are gone, the originals are byte for byte unchanged, and the chain is a completed task in
  History. The Next Action then offers Create ZIP, which makes one archive holding both results. A copied link
  offers QR Code, which makes a PNG on the shelf and offers Copy next. ⌘K finds it.

### Real-path checks

On request, the paths the scripted suite avoids were run for real, with the clipboard backed up first and
restored afterwards (same item, same four types, same sizes; macOS lists the types in a different order).
**11 of 11 passed:** a real `pbcopy` reached the engine through the once-a-second pasteboard check; Copy as
RGB wrote the real clipboard and NotchFlow didn't read its own write back; Undo restored the copy; a real
tracked link (copied with a browser in front, so no Open was offered) became the cleaned link on the
clipboard; Archive Utility really expanded a finished download's ZIP next to it and kept the archive; and
Review on a focus summary opened History. A clipboard history in any other NotchFlow running at the time
would have seen those test copies.

## Measurements

Debug build, collapsed at rest, 30 one-second `top` samples per state, `footprint` for memory:

| State | Mean CPU | Idle wakeups | Footprint |
|---|---|---|---|
| Copy suggestions off | 0.00 % | 0.17 / s | 33 MB |
| Copy suggestions on (pasteboard checked once a second) | 0.00 % | 0.13 / s | 33 MB |

The difference is within noise. Instruments was not run. These are Debug numbers on one machine. They
were taken before the coordinator and work modes; neither adds a timer at rest (work modes schedule one
check only while a mode change is pending), and they weren't measured again.

## Not verified, and why

| Not verified | Why |
|---|---|
| Hand-offs to Maps, Mail, Phone and Finder | They open other apps. The handlers were resolved with `NSWorkspace.urlForApplication(toOpen:)`: `maps://` → Maps, `tel:` → Phone, `mailto:` → the default mail handler. |
| Remind Me, including the Reminders permission prompt | It writes to the person's Reminders and needs their approval. |
| A real Download Center download | Downloads were posted as activity events, not saved by a browser into ~/Downloads. |
| Copy Formatted and Copy as HSL on the real clipboard | Same write path as Copy as RGB and Copy Clean Link, which were checked for real. |
| Cancelling a chain partway through | The cleanup on cancel is unit-tested (`ChainArtifacts.abandon`, files in flight), but the presets finish too fast on small images to cancel by hand in the script. |
| A focus session's end while typing | Mission Complete then only lights the rim, as it always has; the summary is in History but not shown. Not rechecked. |
| VoiceOver announcement and reading order of the glance | Not tested with VoiceOver running. |
| Reduce Motion, multiple displays, full-screen apps | The glance uses the shared reveal and surface motion, which already honor Reduce Motion, and the shared display geometry, but this branch didn't recheck them on screen. |
| Light and dark wallpaper | The glance is drawn on the obsidian surface like every other glance; not rechecked on screen. |

## Known limitations

- Three context sources: the app in front, the clipboard and finished downloads. Others are on the roadmap in
  [02-plan.md](02-plan.md), and none is described as working.
- Suggestions come from copies and finished downloads. Screenshots keep their existing glance, and a download
  no rule fits keeps its plain notice.
- The engine can't know macOS Focus state, another app's microphone or camera, or whether the screen is
  shared. Quiet mode, quiet hours and Hide private details are the controls.
- The secret filter is best effort, as before. Exclusions and Hide private details are the reliable
  controls.
- Escape while a suggestion shows counts as ignored, not dismissed, so it never backs a rule off.
- Work modes are coarse on purpose: three signals, a fixed list of apps per mode, and no window titles or
  content. An app not on the lists counts as General. Study is only chosen.
- Rendered hover shortcuts were reviewed for Developer mode only; the other modes were checked through status.
- The glance's buttons are reachable with the pointer and VoiceOver. The non-activating panel doesn't take
  keyboard focus for a glance, as with every other glance; ⌃⌥Space opens the workspace.
