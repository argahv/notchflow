## What this changes

<!-- One or two sentences. Link the issue: "Closes #123". -->

## Why

## How it was tested

- [ ] `swift test` passes
- [ ] `python3 -I Tests/test_bridge.py` passes (if `Scripts/` or the event contract changed)
- [ ] `bash Scripts/build.sh` builds
- [ ] If I added, moved or removed a Swift file: I ran `python3 Scripts/generate_project.py` and committed `NotchFlow.xcodeproj`
- [ ] Checked on a Mac: <!-- notch / no notch / external display, macOS version -->

<!-- For UI changes, add before/after screenshots or a short recording. Crop out anything personal. -->

## Accessibility and motion

- [ ] New controls have accessibility labels and work from the keyboard
- [ ] Animations respect Reduce Motion; materials respect Reduce Transparency
- [ ] Not applicable

## Privacy and security

- [ ] No new network requests, permissions or entitlements
- [ ] Or: they're listed here and documented in `docs/security/integrations.md`
- [ ] No tokens, personal paths or private data in code, tests, screenshots or logs
