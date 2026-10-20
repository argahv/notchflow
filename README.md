<h1 align="center">NotchFlow</h1>

<p align="center"><b>Your MacBook's notch, alive.</b><br>
The black cutout at the top of your screen grows into a workspace that shows what your AI agents and builds are doing,<br>
taps you on the shoulder only when something needs you, and disappears back into the hardware when nothing does.</p>

<p align="center">
  <img src="docs/media/hero.gif" width="720" alt="The notch at rest with three status dots grows into a compact preview, then into a full workspace listing agents, a failed CI run, a build and a download, and retracts back into the notch.">
</p>

<p align="center">
  <img alt="macOS 14.6+" src="https://img.shields.io/badge/macOS-14.6%2B-black?style=flat-square">
  <img alt="Native SwiftUI and AppKit" src="https://img.shields.io/badge/native-SwiftUI%20%2B%20AppKit-black?style=flat-square">
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-black?style=flat-square">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-black?style=flat-square">
</p>

---

## It's the notch. Just bigger.

Most notch apps put a card under the camera. NotchFlow doesn't. Every view is the same black shape changing
size: it starts as the hardware notch, stretches when you point at it, and flows outward with continuous
corners and shoulders that melt into the bezel. When there's nothing to say, it tucks itself one point
inside the camera housing and you can't tell it's there.

<p align="center">
  <img src="docs/media/resting.png" width="420" alt="At rest: the notch with three small status dots and a count of six.">
</p>

<p align="center">
  <img src="docs/media/light-workspace.png" width="600" alt="On a light wallpaper, the black notch grows straight down into a workspace listing six activities.">
</p>

<p align="center"><sub>Even on a white menu bar there's no seam, no floating card and no drop shadow. It's one shape.</sub></p>

## Approve Claude Code from the notch

Running Claude Code or Codex in a terminal you can't see? NotchFlow follows each session through the
agents' official hooks: which project and branch it's in, what tool it's running, when it's waiting for
you. When it asks for permission, the request appears right at the top of your screen.

<p align="center">
  <img src="docs/media/agent-permission.png" width="600" alt="An open Claude Code card: 'Claude Code wants to use Bash', the command 'pnpm test --filter checkout', Allow once and Deny buttons with a 53-second countdown, then the session's recent steps beside its project, branch, repository and app.">
</p>

- **Allow once** (two presses, so it's never an accident) or **Deny**, sent through Claude Code's and
  Codex's documented `PermissionRequest` hook. Nothing is typed into your terminal.
- If you don't answer, NotchFlow steps aside after a short wait and your terminal's own prompt decides.
- **Recent steps** and **session details** at a glance; **Open Terminal** brings the right app forward.
- Your prompts, Claude's replies and tool input never leave the hook. Only the state and tool name do.

## Everything that needs you, in one stack

<p align="center">
  <img src="docs/media/activity-stack.png" width="600" alt="The activity stack: Claude Code needing permission, a second Claude session waiting, a failed CI run, a build at 64%, Codex working, and an Xcode download with its size so far.">
</p>

Agents, GitHub Actions, local builds and downloads share one stack, ranked by what needs you most. Work
that needs input jumps to the top, failures stay for an hour, and finished tasks slip into History on
their own. Filter by **Agents**, **CI**, **Downloads** or **Done**. Percentages appear only when the source
actually reports one. Otherwise you get an honest spinner.

## Notifications that know the next step

<p align="center">
  <img src="docs/media/notification.png" width="520" alt="A notification grown from the notch: Claude Code, atlas-web, needs permission for Bash, with a blue Review button.">
</p>

The notch lights along its lower edge, grows just enough to say what happened, and offers the one thing
you'd do next: **Review** a request, **Join** a call, **Show** a download in Finder, **Open** a failed run.
It never steals keyboard focus, and it never opens over a note you're typing.

## Small tools, right where you look

<table>
  <tr>
    <td><img src="docs/media/tools.png" alt="The tools launcher: Notes, To-dos, Clipboard, Calendar, Timer, Quick apps, Sound, System, Mirror and Shortcuts."></td>
    <td><img src="docs/media/clipboard.png" alt="Clipboard history with a link, a code snippet, a note and a colour, and a line saying two items were skipped as password-manager or likely-secret copies."></td>
  </tr>
</table>

- **Music**: what's playing in Apple Music or Spotify, with transport controls and a scrubbable timeline.
- **Shelf**: drag files toward the notch. It opens into a drop target and keeps them one click away.
- **Clipboard**: opt-in, kept in memory only, and skips password managers and anything that looks like a key.
- **Meetings**: calls with a Zoom, Meet, Teams, Webex or FaceTime link appear ten minutes early, with **Join**.
- **Download Center**: browser downloads with their real size so far, then the finished file.
- **GitHub Actions**: your repositories' runs, polled efficiently (token optional, kept in Keychain).
- **Focus timer, notes, to-dos, calendar, sound output, system stats, camera mirror, Shortcuts**.
- **⌘K** searches and runs anything, from your keyboard.

It follows what you're doing without getting in the way. With a terminal in front, agents and builds rank
first; with a browser in front, downloads do. It never opens itself.

## Private by design

- No account, no telemetry, no analytics, no server. It makes no network requests unless you add a GitHub
  repository.
- Everything that touches your data is **opt-in**: clipboard, downloads, meetings, agent approvals, GitHub.
- macOS permissions are requested only when you turn on the feature that needs them. NotchFlow never needs
  Accessibility or your microphone.
- History stays on your Mac, in owner-only files. Details: [security and privacy](docs/security/integrations.md).

## Get NotchFlow

There's no signed download yet, so build it yourself in about a minute. You need macOS 14.6 or later and
Xcode 16 or later.

```bash
git clone https://github.com/argahv/notchflow.git
```

```bash
cd notchflow && bash Scripts/build.sh
```

```bash
open build/NotchFlow.app
```

That gives you an unsigned universal app. To keep it in `/Applications` with launch at login and stable
permissions, open `NotchFlow.xcodeproj`, choose your signing team, and Run.

**First steps.** Hover the notch, or press **⌃⌥Space** anywhere. Pick a mode in Settings: **Minimal**,
**Dynamic** or **Developer**. To follow Claude Code or Codex, open **Settings › Agents**, press **Copy**, and
merge the snippet into `~/.claude/settings.json` (or `~/.codex/hooks.json`). NotchFlow never edits those
files for you. [More on agents](docs/architecture/agent-integrations.md).

| Shortcut | Does |
|---|---|
| ⌃⌥Space | Open or close, from anywhere |
| ⌘1 … ⌘5 | Activity, Music, Shelf, Tools, History |
| ⌘K | Search and commands |
| Esc | Back, then close and return to your app |

Works on Macs without a notch too: it draws one at the top centre of the display you choose.

## From your own scripts

Anything can post to the notch. Wrap a command and see it run, finish or fail:

```bash
python3 Scripts/notchflow.py run --title 'Web tests' -- npm test
```

Or publish your own status:

```bash
python3 Scripts/notchflow.py emit --title 'Deploy ready for review' --phase waiting
```

Events go to an owner-only local inbox; there's no listening port. See the [event contract](docs/INTEGRATIONS.md).

## Status

**Developer preview.** NotchFlow is built and tested on a MacBook Air with a notch: 49 Swift and 22 Python
tests, end-to-end hook checks, and frame-by-frame recordings of its transitions. Some things haven't
been checked against live services yet, notably a live Claude Code or Codex session with the hooks
installed, and file drags onto the notch. See the [validation report](docs/obsidian-silver/02-validation.md)
and [progress](docs/implementation/progress.md).

The screenshots on this page are the real app. They were captured over a neutral wallpaper and menu bar, so
no personal desktop appears, and they use demo projects.

## For contributors

```bash
swift test
```

```bash
python3 -I Tests/test_bridge.py
```

- `Sources/NotchCore`: the testable core, covering the activity engine, ranking, geometry, GitHub mapping,
  context rules and content rules.
- `Sources/NotchFlow`: the app. `Shell` (surface and layout), `Design` (tokens, silhouette, materials,
  motion), `Surfaces` (features), `Features` (providers and services), `Window` (panel, input, geometry).
- `Scripts`: the project generator, the event CLI and agent hooks, and build and notarization scripts.

Design and architecture: [Obsidian & Silver design](docs/obsidian-silver/01-design.md) ·
[activity engine](docs/architecture/activity-engine.md) · [agent integrations](docs/architecture/agent-integrations.md) ·
[context engine](docs/architecture/context-engine.md) · [motion](docs/design/motion-system.md) ·
[acceptance tests](docs/testing/acceptance-tests.md).

<p align="center"><sub>Original implementation; no proprietary source, assets or extracted shaders.</sub></p>
