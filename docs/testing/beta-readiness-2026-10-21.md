# Interaction-polish beta checklist (2026-10-21)

Branch: `improve/interaction-reliability-beta-20261021`. Keep `main` untouched until the beta gate passes.

## What changed

- Trackpad notch activation now requires deliberate precise vertical scrolling; momentum and ordinary scrolling in hover/workspaces no longer open the workspace.
- Dismissal uses the current visible surface bounds rather than the transition panel's temporarily oversized frame.
- Dynamic hover preserves the current preview and split arrangement during pointer interaction, including an inline play/pause click. A critical agent request may still take priority.
- Surface reflow no longer forces the same quick animation on changes that should use the continuous, interruptible surface spring.
- The hook refuses world-readable or symlinked approval responses; the native app refuses to overwrite an existing pending answer. Python fixtures verify the same owner-only protocol.
- The Music UI updates its transport and seek state only after a successful player command.
- Shelf thumbnail caching uses memory-pressure-aware NSCache (24 images, approximate 32 MiB cap), includes pixel size in cache keys, and discards cached previews on removal/undo.

## Automated gate

Check the latest **Verify** GitHub Actions run for this branch:

- `python3 -m unittest discover -s Tests -p 'test_*.py' -v`
- `swift test` on macOS
- `bash Scripts/build.sh` (universal, unsigned development build)
- `xcrun -sdk macosx metal -c Resources/LiquidGlass.metal -o build/LiquidGlass.air`
- Generated Xcode project diff remains clean

Do not promote if any of these fail. The Verify artifact is **unsigned**; it is for testing, not distribution as a notarized release.

## Must-run macOS manual acceptance

1. **Geometry:** On a built-in notch with light and dark wallpapers, check no gap or shoulder seam at rest, hover, expanded, and collapse. Repeat on an external display with simulated notch.
2. **Hover & motion:** No active task (Quick Access), music only, Claude running, Claude requiring input, two activities split, and a failed CI event. Hover and click each preview and verify its destination. Move quickly into/out of the surface; switch feature while it is still expanding. Check Reduce Motion and Reduced Transparency.
3. **Trackpad:** Scroll within an expanded Activity list without triggering a second expansion. Ordinary wheel/tiny trackpad movement while collapsed should not open the workspace. A deliberate two-finger vertical gesture on the resting notch should open it.
4. **Agent approvals:** Opt in, install official Claude Code hooks in Settings, request a harmless tool permission, allow and deny separately, decline Automation permissions where relevant, let a request time out, and confirm late/duplicate approvals cannot be accepted. Test a Codex session separately if Codex is installed. Verify request text never reaches History.
5. **Music:** Grant Automation when prompted. Play/pause, next/previous and scrub in Music; revoke permission and confirm error feedback without falsely changing play or scrub state.
6. **Shelf:** Drag a real Finder file onto the notch, open from Shelf, drag out, remove and undo. Scroll a Shelf with more than 24 files (at least two thumbnail sizes), then check for retained image growth.
7. **Integrations:** Connect a read-only GitHub Actions token to test private runs, test a real browser download and calendar call, verify clipboard privacy skips, and confirm system services behave correctly after sleep/wake and lock/unlock.
8. **Keyboard/focus:** Use ⌃⌥Space, ⌘K, shortcuts, Escape; edit a note and test IME composition. Passive updates must never steal foreground focus.
9. **Accessibility:** VoiceOver, keyboard-only controls, high contrast, Reduce Motion, Reduce Transparency, and offline/no-permissions startup.

These are **not** certified by a CI run. Record hardware results before release.

## Measure idle energy and memory

Run on the **same Mac** and compare two sessions at the same sampling interval:

```bash
NOTCHFLOW_PROFILE_OUTPUT=idle.csv bash Scripts/profile.sh 1800 10
NOTCHFLOW_PROFILE_OUTPUT=interactive.csv bash Scripts/profile.sh 1800 10
```

During `idle.csv`, leave NotchFlow collapsed and don't interact. During `interactive.csv`, exercise hover, Shelf thumbnails, Music, and multiple Activity rows. Repeat the idle run after the interactions; the critical question is whether resident memory stabilizes rather than rising unbounded.

This script records timestamp, PID, %CPU, and resident KB only. It doesn't capture the display, agent requests, clipboard, or credentials. RSS alone cannot establish a memory leak: use Instruments Allocations / Leaks and Activity Monitor Energy if growth persists. Observe Low Power Mode separately.

## Beta distribution gate

- CI succeeds at the *final* branch head.
- All critical manual paths above have been exercised on a notched Mac.
- No agent-approval race or unintended focus takeover remains.
- Idle energy and post-interaction memory are measured and acceptable.
- Accessibility passes on supported macOS 14.6+.
- Sign with Developer ID, notarize and staple through the existing `Scripts/release.sh` / `Release` workflow, then validate Gatekeeper on a clean Mac.
- Publish a checksum and accurate changelog. Don't claim the unsigned CI artifact is a signed beta.

**Not done by this branch:** a signed/notarized release, third-party service authorization, real hardware drag-and-drop testing, and a definitive root-cause analysis of previously reported memory growth. Those require a Mac and the applicable user accounts/permissions.
