# Verification status and Mac acceptance checklist

## Executed in the creation environment

- Python 3.12 bridge suite: **9 tests passed** (validation, atomic writes, permissions, symlink rejection, CLI smoke, hook mapping and direct subprocess execution).
- Swift tree-sitter parsing: all Swift source/test/manifest files parsed without syntax errors. **This does not type-check against Apple SDKs.**
- Xcode project: deterministic regeneration and source/resource membership checked.
- Property lists and shared scheme: parsed structurally.
- Shell scripts: syntax checked with bash.

No Swift compiler, Xcode, Metal compiler or macOS runtime was available. `swift test`, `xcodebuild`, native UI, permissions, actual Claude sessions, fullscreen/Spaces, memory and battery use are **not run**. The CI workflow is configured; no CI success is claimed before an actual run.

## First Mac run

- [ ] Select a signing team, build Debug and fix any SDK/type-check errors.
- [ ] Run `swift test`; all nine core tests pass.
- [ ] Build universal Release and compile the Metal source using the workflow command.
- [ ] App launches as a menu-bar agent; settings and Quit remain reachable if overlay is disabled.
- [ ] No permissions appear at launch. Unsupported/denied tools show usable fallback states.

## Window and input

- [ ] Actual notch: header avoids camera, no gap at top, controls fit left/right.
- [ ] External display: simulated notch works; disabling simulation hides it appropriately.
- [ ] Rearrange monitors with negative/nonzero origins; change scaling, disconnect selected monitor.
- [ ] Spaces, fullscreen video, fullscreen IDE, menu-bar auto-hide, Mission Control and Stage Manager.
- [ ] Closed overlay consumes clicks only within its visible surface. Check rounded transparent corners.
- [ ] Rapid enter/leave and expand/collapse do not clip or stick.
- [ ] First-click controls work without activating unrelated windows.
- [ ] Keyboard shortcut works and reports conflicts; Escape restores the previous app.
- [ ] Text input retains focus; pinned/drag/edit states resist accidental collapse.
- [ ] File drag expands Shelf and completes; cancelled drag returns to a usable state.

## Data and services

- [ ] Timer survives relaunch and sleep, completes once; paused timer stays paused.
- [ ] Notes and to-dos persist; save failures are visible. No data reset on store failure.
- [ ] Shelf original remains untouched; move original, remove drive, restore drive, drag to another app.
- [ ] Removing shelf reference and Undo works; access failure allows manual re-adding.
- [ ] Music and Spotify each prompt once and work when active; stopped track and denied permission recover.
- [ ] Calendar/Reminders granted/denied/revoked states, event changes and reminder completion.
- [ ] Camera turns off on tool change, close, privacy, sleep and lock; check hardware indicator.
- [ ] Launch at login from a signed `/Applications` bundle; disabling unregisters.
- [ ] Battery values correct on MacBook and gracefully absent on desktops.

## Activities

- [ ] CLI emit, command success/failure, interruption and heartbeat on a real Mac.
- [ ] Real Claude SessionStart, permission/idle Notification and Stop fixtures match actual hook inputs.
- [ ] Out-of-order event does not replace newer state; burst events deduplicate.
- [ ] No incoming update rearranges existing activity buttons while open.
- [ ] Snooze, expiry and recent history remain understandable across relaunch.
- [ ] Privacy hides project/file/note details; quiet mode suppresses previews.
- [ ] No task URL opens without a user action; no shell command is accepted through event JSON.

## Rendering and accessibility

- [ ] Performance and Balanced work with Screen Recording denied.
- [ ] Ultra explicit permission, correct selected display/crop, no recursive overlay capture.
- [ ] Switching away/collapsing stops capture; permission revocation falls back.
- [ ] Reduce Motion, Reduce Transparency, VoiceOver, increased contrast and keyboard navigation.
- [ ] Measure CPU, memory, energy and frame timing on battery and AC with Instruments.
- [ ] Test low-power mode, Intel/Apple Silicon, 1×/2× and HDR displays.

## Known scope limits

- No system-wide Now Playing (only Music and Spotify), no Spotify artwork (it is remote; Music artwork is read locally), no audio waveform, Bluetooth battery, OS HUD replacement, service monitoring, remote CI or automatic presentation detection.
- Multiple plain-text notes; clearing completed to-dos has no undo yet. Shelf supports local files/folders, not text or clipboard history.
- Completion/expiry while asleep is handled on wake, not by a background wake alarm or system notification.
- The one-second clock runs only while a focus timer counts down. Measured idle cost is in [docs/redesign/05-qa-report.md](redesign/05-qa-report.md).
- Media AppleScript runs synchronously with a two-second timeout. A production adapter needs responsiveness profiling and further isolation if it blocks.
- At rest the panel covers only the silhouette's bounding box, so its small transparent corners can still intercept clicks; during a transition (≤ 0.9 s) it is briefly larger. Exact shape hit testing is a follow-up gate.
- SwiftData migration, advanced diagnostics export, full strict-concurrency adoption and signed auto-updates remain future work.
