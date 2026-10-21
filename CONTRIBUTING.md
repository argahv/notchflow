# Contributing to NotchFlow

Thanks for wanting to help. NotchFlow is a native macOS app (SwiftUI + AppKit, a little Metal, and a small
Python bridge for agent hooks), and it's looking for **Swift, SwiftUI, AppKit, macOS graphics and
accessibility contributors**. You don't need to be an expert: several issues are small and well scoped.

- **Start here:** [good first issues](https://github.com/argahv/notchflow/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
  · [help wanted](https://github.com/argahv/notchflow/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)
- **Questions:** [Discussions › Q&A](https://github.com/argahv/notchflow/discussions/categories/q-a)
- **Ideas:** [Discussions › Ideas](https://github.com/argahv/notchflow/discussions/categories/ideas)
- **Security problems:** please report privately, see [SECURITY.md](SECURITY.md).

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). By contributing you agree your work
is released under the project's [MIT License](LICENSE).

## Requirements

| | |
|---|---|
| Mac | Apple silicon or Intel. A notched MacBook is great but not required: NotchFlow draws a notch on other displays. |
| macOS | 14.6 or later to run. CI builds on macOS 15. |
| Xcode | 16 or later (Swift 5.10+). |
| Python | 3.9+ for the bridge and its tests (standard library only). |

No package manager, no third-party dependencies, no XcodeGen.

**No Mac?** You can still help: the Python bridge and its tests run anywhere, and documentation issues
don't need Xcode.

## Clone, build and run

```bash
git clone https://github.com/argahv/notchflow.git
cd notchflow
bash Scripts/build.sh          # universal, unsigned Release build → build/NotchFlow.app
open build/NotchFlow.app
```

Or open `NotchFlow.xcodeproj` in Xcode and run the **NotchFlow** scheme (Debug). Debug builds include a
scripted QA channel (see [Debugging without special hardware](#debugging-without-special-hardware)).

An unsigned build is a new app to macOS each time, so it asks again for folder access after every rebuild.
To keep permissions, sign with any identity you have (`security find-identity -p codesigning -v`):

```bash
NOTCHFLOW_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" bash Scripts/build.sh
```

Quit any installed copy of NotchFlow before running yours. A Debug build shares its data folder
(`~/Library/Application Support/NotchFlow`) with the installed app.

## Tests

```bash
swift test                          # 110 tests for NotchCore (macOS)
python3 -I Tests/test_bridge.py     # 24 tests for the event CLI and agent hooks (any OS)
```

CI ([`verify.yml`](.github/workflows/verify.yml)) runs both, checks that the Xcode project is up to date,
builds Debug and universal Release, and compiles the Metal shader. A pull request needs a green run.

Expectations:

- **New logic in `NotchCore` gets unit tests.** Use fixed dates, never `Date()`. Test names are full
  sentences: `testPassiveAttentionNeverTakesTheSurfaceFromADragOrItsResult`.
- **Changes to `Scripts/notchflow.py`** get a test in `Tests/test_bridge.py`, including a check that no
  prompt, command or tool input leaks into published events.
- **UI changes** need before/after screenshots or a short recording in the PR, and a note of what you checked
  on screen (notch or no notch, light and dark wallpaper, Reduce Motion).

## Architecture in five minutes

```
Sources/
  NotchCore/     Pure, deterministic rules. Foundation only. Unit-tested.
  NotchFlow/     The app.
    AppModel.swift   Coordinates state; every visual change goes through AppModel.commit
    Shell/           The one surface: layout, routing, overlay, split island, heartbeat
    Surfaces/        Feature views: Activity, Music, Shelf, Tools, History, ⌘K, Notes, Capture…
    Features/        Providers and services: event inbox, agent approvals, GitHub, media, calendar…
    Design/          Tokens, the notch silhouette, materials, controls, Motion
    Graphics/        Experimental "Ultra" glass: ScreenCaptureKit backdrop + MTKView
    Window/          NSPanel, input, display geometry, Debug channel
Resources/       Info.plist, entitlements, LiquidGlass.metal (compiled at runtime, Ultra only)
Scripts/         Project generator, event CLI + agent hooks, build/release/notarize, profiler
Tests/           NotchCoreTests (Swift), test_bridge.py (Python)
docs/            Architecture, design, security, testing and progress notes
```

Key ideas:

- **Two halves.** `NotchCore` is a Swift package target with no UI: interaction state, geometry, ranking,
  attention, hover and split island, portal, actions, Time Travel, sound, GitHub cadence and the event
  contract. If logic can be pure, put it there and test it. `NotchFlow` is the app; it exists only in the
  Xcode project, which compiles all of `Sources/` into one module (so app files don't `import NotchCore`).
- **One shape.** Every view is the same black silhouette changing size
  ([`Design/NotchShape.swift`](Sources/NotchFlow/Design/NotchShape.swift),
  [`NotchCore/SurfaceGeometry.swift`](Sources/NotchCore/SurfaceGeometry.swift)). Surface sizes come from
  data-driven size contracts, never from measuring rendered views.
- **One transaction.** Visual changes go through `AppModel.commit`, animated with a preset from
  [`Design/Motion.swift`](Sources/NotchFlow/Design/Motion.swift). Don't add ad-hoc `.animation(...)` curves.
- **Events come from a file spool, not a socket.** Agents and scripts write owner-only JSON into an inbox
  ([`Features/EventBridge.swift`](Sources/NotchFlow/Features/EventBridge.swift),
  [`Scripts/notchflow.py`](Scripts/notchflow.py)). The [event contract](docs/INTEGRATIONS.md) is the public API.
- **State.** Services and models are `@MainActor final class … : ObservableObject` with `@Published`;
  SwiftData stores notes, to-dos and shelf items. Callbacks from AppKit and Dispatch hop with
  `MainActor.assumeIsolated`.

Deeper reading: [activity engine](docs/architecture/activity-engine.md) ·
[agent integrations](docs/architecture/agent-integrations.md) ·
[context engine](docs/architecture/context-engine.md) · [motion](docs/design/motion-system.md) ·
[design as built](docs/obsidian-silver/01-design.md) · [dynamic hover](docs/obsidian-silver/03-dynamic-hover.md) ·
[security and privacy](docs/security/integrations.md) · [acceptance tests](docs/testing/acceptance-tests.md).

## The Xcode project is generated

`NotchFlow.xcodeproj` is written by [`Scripts/generate_project.py`](Scripts/generate_project.py) and
committed. **After adding, removing or renaming any Swift file under `Sources/`**, run:

```bash
python3 Scripts/generate_project.py
```

and commit the project change with your PR. CI regenerates it and fails on any diff. Don't hand-edit the
`.pbxproj`, and don't commit Xcode user data. New files under `Tests/` don't need a regeneration.

## Conventions

- **Doc comments explain why.** Every type and most functions have a `///` comment in plain prose about
  behaviour and intent. Group with `// MARK: -`.
- **Design tokens, not literals.** Colours, spacing, radii and type come from
  [`Design/Tokens.swift`](Sources/NotchFlow/Design/Tokens.swift). Animations come from `Motion`.
- **Match the surrounding code.** There's no SwiftLint or swift-format configuration; keep to the style of
  the file you're in and keep diffs focused. Don't reformat unrelated code.
- **No new dependencies** without discussing it in an issue first.
- **Copy is product writing.** UI strings are short, specific and honest ("an honest spinner" rather than a
  fake percentage). Say what happened and the one next step.

## Accessibility (required, not optional)

- Every control has an accessibility label; icon-only buttons especially. Status that's shown by colour also
  needs words (`accessibilityValue`).
- Everything reachable by pointer is reachable by keyboard.
- Animations respect **Reduce Motion** *and* the in-app Calm motion setting: use `Motion.reduced`, not the
  `accessibilityReduceMotion` environment value alone. Every `Motion` preset already has a reduced form.
- Materials respect **Reduce Transparency** (see `Design/Materials.swift`).
- If you can, test with VoiceOver (⌘F5) and note it in the PR.

## Security and privacy expectations

NotchFlow is local-first: no account, no telemetry, no server. Keep it that way.

- No new network requests, macOS permissions or entitlements without calling them out in the PR and
  documenting them in [docs/security/integrations.md](docs/security/integrations.md).
- Anything touching user data is opt-in and off by default.
- Agent hooks never publish `prompt`, `last_assistant_message`, `tool_input`, `tool_response` or
  `transcript_path`.
- Event content is never executed. App files stay owner-only (0700/0600, no symlinks followed).
- Never commit tokens, certificates, personal paths or real screenshots of your desktop.

## Branches and pull requests

1. Comment on the issue you'd like to take so nobody duplicates work. For something without an issue, open
   one (or a Discussion for bigger ideas) before writing a lot of code.
2. Fork, then branch from `main`: `fix/<short-name>`, `feat/<short-name>`, `docs/<short-name>`,
   `a11y/<short-name>`, `perf/<short-name>` or `test/<short-name>`.
3. Keep PRs small and focused; one issue per PR is ideal. Write commit subjects as plain sentences in the
   imperative ("Label the Search dock button for VoiceOver").
4. Open the PR against `main`, fill in the template, link the issue (`Closes #123`), and add screenshots for
   UI changes.
5. A maintainer reviews. Expect questions and requested changes; that's normal. External PRs are merged by a
   maintainer after review and a green CI run.

## Proposing features

Open a [feature request](https://github.com/argahv/notchflow/issues/new?template=feature_request.yml) or
start in [Discussions › Ideas](https://github.com/argahv/notchflow/discussions/categories/ideas). Good fits:

- work locally, with no new account or server;
- stay quiet until something actually needs the user, and never steal focus;
- grow out of the notch rather than floating a separate card;
- are honest about what they know (no fake progress, no claims the source didn't make).

Large features (new providers, new rendering modes, plugin systems) need a short design note in the issue
before code.

## Debugging without special hardware

Debug builds watch `~/Library/Application Support/NotchFlow/debug` for `*.cmd` files and run each line as a
command, which lets you reproduce states without a real drag, trackpad gesture or AirPods. Examples:

```bash
mkdir -p ~/Library/Application\ Support/NotchFlow/debug
printf 'nowplaying:Night Drive|Demo Artist\nhover:enter\n' > ~/Library/Application\ Support/NotchFlow/debug/01.cmd
```

The full command list lives in [`Window/DebugChannel.swift`](Sources/NotchFlow/Window/DebugChannel.swift)
(documenting it is [a help-wanted task](https://github.com/argahv/notchflow/issues/10)).
To post realistic activity, use the event CLI:

```bash
python3 Scripts/notchflow.py run --title 'Web tests' -- sleep 20
python3 Scripts/notchflow.py emit --title 'Deploy ready for review' --phase waiting
```

## New to Swift or macOS?

- Pick an issue labelled **good first issue**. Each one lists the exact files, acceptance criteria and how to
  test it.
- `NotchCore` is the friendliest place to start: plain Swift, fast tests, no UI.
- Python-only issues (the hook in `Scripts/notchflow.py`) work on Linux too.
- Stuck on a build? Ask in [Q&A](https://github.com/argahv/notchflow/discussions/categories/q-a) with your
  macOS and Xcode versions and the error. There are no silly questions.
- Not sure where you fit? Open an
  ["I'd like to contribute"](https://github.com/argahv/notchflow/issues/new?template=contributor_onboarding.yml)
  issue and say what you're interested in.
