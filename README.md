# NotchFlow

A native macOS notch workspace for developer attention, music, files and small daily tools.

**Status: 0.1 developer preview. Source implementation, not a verified release.** Created in a Linux environment without Xcode or a Swift compiler. The Python bridge tests and Swift syntax parsing were run; native compilation, Metal execution, visual quality, permissions and hardware behavior have **not** been verified. The macOS CI workflow builds the app and runs the Swift core tests when this repository is pushed to GitHub.

## Build on your Mac

Requires macOS 14.6+, Xcode 16+ with its command-line tools, and Python 3.9+ for the CLI and project generator. Swift source uses Swift 5 language mode on the modern toolchain while the native services are validated; adopting strict Swift 6 concurrency is a follow-up, not an existing guarantee.

```bash
open NotchFlow.xcodeproj
```

Select the **NotchFlow** scheme, set your signing team under Signing & Capabilities, and Run. The app lives in the menu bar and has no Dock icon. Use its menu to open Settings or quit.

Alternatively, produce an unsigned universal app:

```bash
bash Scripts/build.sh
open build/NotchFlow.app
```

Use an appropriately signed bundle in `/Applications` for realistic permission and launch-at-login testing. The unsigned local build is for development, not public distribution. No certificates, account credentials or signing team are included.

## Interaction

- At rest the notch shows at most one status on each side (a waiting task, what's playing, the timer, battery) and hides behind the camera housing when there is nothing to say. Approaching it lights the rim.
- Hover: after a short, configurable delay a one-row glance shows the most relevant item; click it, the band, or scroll at the notch to open the workspace there.
- Open, the band beside the notch is the dock: Activity, Music and Shelf on the left, Tools and History on the right, search (⌘K) and Pin and More (quiet, privacy, settings) at the edges. The surface sizes itself to its content.
- **Control–Option–Space:** open/close globally without Accessibility permission.
- **Escape:** back one level, then close and return focus to the previous app.
- **Command–1…5:** Activity, Music, Shelf, Tools, History; **Command–K:** search and run commands.
- **Pin:** keep open when the pointer leaves; **Quiet:** suppress automatic glances.
- Notifications by severity: failures (coral) preempt, waiting tasks (amber) and completions (mint) glance briefly; nothing opens over a note being edited — the rim lights and it waits.
- **Privacy:** conceal project details, shelf and tool content. It is a manual switch; automatic screen-sharing detection is not implemented.
- File drag: reveal the shelf; references preserve originals; undo restores a removed shelf reference.

Existing activity rows retain their position while the workspace is open. Newly arriving activities append; completed rows remain until the next opening. No automatic action runs from an activity event.

## Implemented source

| Area | Included behavior |
| --- | --- |
| Overlay | Nonactivating AppKit panel, first-click handling, safe-area geometry, selected display, simulated notch, display-change recovery |
| Activity engine | Versioned events (v1 + typed v2 states, categories, agents, requests), validation, ranking, deduplication, out-of-order protection, expiry, snooze, pin, hide, history; dynamic task stack with filters |
| Agents | Claude Code and Codex hook adapter (tool, waiting, permission states), optional Allow/Deny of permission requests through the documented hook output, Open ‹host app› |
| Developer tools | Local CLI, command wrapper with heartbeat, GitHub Actions polling (optional Keychain token) |
| Context and modes | Frontmost-app ranking (never auto-opens), Minimal / Dynamic / Developer presets |
| Clipboard and downloads | Opt-in memory-only clipboard history with password-manager and secret filtering; Download Center with honest states |
| Timer | Start/pause/resume/cancel, persisted deadline, one-time completion after sleep/relaunch |
| Shelf | Security-scoped bookmarks, local file picker/drop, outbound drag, open/reveal, remove and undo, 100-reference cap |
| Music | Opt-in Music/Spotify AppleScript adapters, title/artist, play/pause/previous/next, progress; polls only while the Music tab is visible |
| Productivity | SwiftData plain-text scratch note and local to-dos, EventKit events/reminders, meeting reminders with Join, camera mirror, quick apps, named Shortcut launcher |
| System | Internal Mac battery/charging data, opt-in low-battery alerts, sound output switching, on-demand CPU/memory/thermal, configurable login item, sleep/lock cleanup |
| Appearance | Solid Performance, native-material Balanced, experimental Metal/ScreenCaptureKit Ultra; accessibility preferences |
| Delivery | Checked-in Xcode project, deterministic generator, universal build script, signing/notarization script, CI, tests and manual verification plan |

“Implemented source” means code exists, not that platform integration has passed a Mac test. See [verification status](docs/VERIFICATION.md) before treating anything as release-ready.

## Publish an activity

Launch NotchFlow, then run:

```bash
python3 Scripts/notchflow.py emit \
  --source terminal --id review-42 --phase waiting \
  --title 'Review the implementation' --summary 'The change is ready for your input.'
```

Wrap a build or test command:

```bash
python3 Scripts/notchflow.py run --source build --id web-tests \
  --title 'Web tests' -- npm test
```

The wrapper passes arguments directly to the process, preserves its exit status, and emits lifecycle/heartbeat events. There is no shell interpolation. Add `--action-url 'https://…'` or an explicit `file:///…` / `vscode://…` link to return to a task. Only a user click opens a link.

The app watches `~/Library/Application Support/NotchFlow/inbox`. Directories are owner-only; each event is written to a temporary file and atomically renamed. Other apps running as the same user can publish events: this is a local user trust boundary, not an isolation boundary against another app under your account.

See [event contract and Claude setup](docs/INTEGRATIONS.md).

## Visual modes and permissions

**Performance:** opaque black, no backdrop capture. **Balanced:** native behind-window material, dark tint and highlights; the default. **Ultra:** optional cropped screen capture at 10 fps, app exclusion, rounded-distance refraction, slight dispersion and edge lighting in an on-demand Metal view. Frames remain in memory and are discarded when closed/hidden, asleep or locked. The effect and power cost require real-device tuning.

Nothing requests camera, calendar, reminders or screen access at launch. Use the relevant tool or Ultra permission button explicitly. Music controls request Automation permission when used. No microphone, network listener, private MediaRemote framework, license checks or telemetry is included.

## Verify

```bash
python3 -m unittest discover -s Tests -p 'test_*.py' -v
swift test
bash Scripts/build.sh
```

`swift test` covers the Foundation-only core. Native integration requires the [manual Mac checklist](docs/VERIFICATION.md). The CI Metal step compiles the shader separately even though the app loads its source at runtime, catching shader errors before delivery.

## Architecture and roadmap

- `Sources/NotchCore`: deterministic interaction, activity queue, geometry and countdown; independently testable Swift package.
- `Sources/NotchFlow/Window`: panel lifecycle, screen geometry, tracking and keyboard shortcut.
- `Sources/NotchFlow/Graphics`: native material, screen capture and on-demand Metal renderer.
- `Sources/NotchFlow/Features`: integrations and widget views.
- `Sources/NotchFlow/Models.swift`: SwiftData models and preferences.
- `Scripts`: project generator, event publisher, build and notarization tools.

The app target compiles core sources directly. The package compiles the same core sources for tests, so there is no third-party package resolution or duplicate import in the app target. Regenerate the Xcode project after adding sources with `python3 Scripts/generate_project.py`.

Liquid Workspace 2.0: [implementation progress](docs/implementation/progress.md), [activity engine](docs/architecture/activity-engine.md), [agent integrations](docs/architecture/agent-integrations.md), [context engine](docs/architecture/context-engine.md), [design](docs/design/liquid-workspace.md), [motion](docs/design/motion-system.md), [security](docs/security/integrations.md), [acceptance tests](docs/testing/acceptance-tests.md).

See [architecture and next milestones](docs/ARCHITECTURE.md) and the [Liquid Workspace redesign notes](docs/redesign/00-current-state-audit.md) (design system, window and state, motion, rendering, QA report). Licensing, Sparkle updates, third-party plugin distribution, private media APIs, Bluetooth discovery and system HUD interception are intentionally future work.

Original implementation; no proprietary source, assets or extracted shaders are used.
