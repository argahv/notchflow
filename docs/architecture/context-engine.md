# Context engine

The app in front changes **which work ranks first**, and nothing else. It never opens, expands or focuses the
notch. Sources: `Sources/NotchCore/ContextRules.swift`, `AppModel.updateContext`.

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
