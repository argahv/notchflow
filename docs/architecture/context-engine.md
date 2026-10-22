# Context engine

Context reaches NotchFlow as typed, privacy-classified events from observers that run only while a feature
uses them (`NotchCore/ContextEvents.swift`, `Features/ContextEngine.swift`). Three observers exist:

| Observer | Runs while | Feeds |
|---|---|---|
| App in front | Follow the app in front, or Follow what I'm doing (work mode), is on | Ranking (below) and the work mode ([ADR-8](../sixth-sense/01-architecture.md#adr-8--work-modes-change-whats-offered-never-whether-the-notch-opens)) |
| Clipboard | Suggest from what you copy is on | Suggestions ([Sixth Sense architecture](../sixth-sense/01-architecture.md)) |
| Finished downloads | Suggest for finished downloads is on | A suggestion in place of the download's notice ([ADR-9](../sixth-sense/01-architecture.md#adr-9--a-finished-download-gets-one-glance-and-a-focus-session-one-summary)) |

`ContextGate` coalesces each source: quick ⌘-Tab cycling settles on the app you stop at, and copying the same
thing twice in a row counts once. Settings › Diagnostics › Context Inspector shows which sources run, what
they passed, and what the suggestion engine decided, without content.

## App in front

The app in front changes **which work ranks first**, and nothing else. It never opens, expands or focuses the
notch. Sources: `Sources/NotchCore/ContextRules.swift`, `AppModel.applyContextBoost`.

## Rules

| Frontmost app | Boosted categories |
|---|---|
| Terminals and editors (Terminal, iTerm2, Ghostty, WezTerm, Warp, kitty, Alacritty, VS Code and forks, Zed, Xcode, JetBrains IDEs, Sublime, Nova, Claude, Codex) | agent, build, ci, deploy |
| Browsers (Safari, Chrome, Firefox, Arc, Brave, Edge, Opera, Vivaldi) | download, ci |
| Calling apps and Calendar (Zoom, Teams, FaceTime, Webex, Calendar) | meeting |
| Anything else | none |

Input is `NSWorkspace.didActivateApplicationNotification`: no polling, no window titles, no screen content,
and nothing is recorded. NotchFlow taking focus (typing a note, the command palette) keeps the previous
context. The boost feeds `RankingContext.boosted` (see [activity-engine.md](activity-engine.md)): running
work in a boosted category scores 500 instead of 300, and other tiers get +20. Urgent work (needs input,
failures) always stays above boosted running work, which is covered by a test.

While the workspace is open, its row order is frozen, so a context change re-ranks the glance and the
resting indicator but doesn't reshuffle rows under the pointer.

Turn it off with Settings › Mode › "Follow the app in front".

## Product modes

Modes are **presets**, not states. Choosing one writes a fixed set of preferences once. Changing any of them
afterwards shows "Custom", and nothing is reverted behind your back.

| | Quiet mode | Follow app | Hover delay | GitHub Actions |
|---|---|---|---|---|
| Minimal | on | off | 0.25 s | off |
| Dynamic (defaults) | off | on | 0.12 s | off |
| Developer | off | on | 0.12 s | on (polls only the repositories you add) |

The battery indicator is a personal display choice, so it isn't part of any preset; it's off by default and
shown only when turned on in Settings.

Features that need a permission or personal data stay separate opt-ins in every mode: clipboard history,
Download Center, meeting reminders, low-battery alerts and agent approvals. Modes are in Settings › Mode and
the command palette ("Use Developer mode").

## Tests

`Tests/NotchCoreTests/ContextRulesTests.swift`: boosts per app class, boost vs. urgency ordering, every
mode distinct, every mode recognized, a changed setting reads as custom.
