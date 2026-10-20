# Liquid Workspace

NotchFlow is one surface that grows out of the notch, shows what needs you, and goes quiet when nothing
does. Visual tokens and materials are in [redesign/01-design-system.md](../redesign/01-design-system.md);
motion is in [motion-system.md](motion-system.md).

## States of the surface

| State | What it shows |
|---|---|
| Resting | The notch, plus one compact status at most: tone dots and a count for several activities, a timer, music, or battery when enabled. Urgent work (needs input, failures) outranks music. |
| Glance (hover or notification) | The top-ranked item with its own next action (Review, Join, Show in Finder, Open run, View) and the next tasks peeking out as layers |
| Workspace | Dock (search, Activity, Music, Shelf, Tools, History, pin, menu) above the chosen feature |

## Features

- **Activity stack**: filters All / Agents / CI / Downloads / Done; detail cards with Open, Snooze, Pin,
  Hide (stack only) and Remove (History, finished items only); agents grouped by project.
- **Agent command center**: Claude Code and Codex sessions from their hooks; tool in use, waiting, needs
  permission; optional Allow once / Deny from the notch; Open ‹host app›. See
  [agent-integrations.md](../architecture/agent-integrations.md).
- **GitHub Actions**: runs for the repositories you add, polled; failures stay for an hour.
- **Download Center**: browser downloads with their real size so far, then the finished file.
- **Meeting reminders**: calls with a recognized join link, with Join.
- **Tools**: Notes, To-dos, Clipboard, Calendar, Timer, Quick apps, Sound, System, Mirror, Shortcuts.
- **Command palette** (⌃⌥Space, then ⌘K): features, tools, notes, recent activity, modes.
- **Modes**: Minimal, Dynamic, Developer presets ([context-engine.md](../architecture/context-engine.md)).

## Principles kept throughout

- Color means something: amber for waiting on you, coral for genuine failure, mint for success and live,
  blue for in progress, iris for interaction.
- No fabricated progress: a percentage appears only when the source reports one (the command wrapper
  with `--progress`, never GitHub runs, agents or downloads).
- No dead buttons: actions appear only when they can work (Allow only while a hook is actually waiting;
  Open ‹app› only when that app resolves; Join only for a recognized link).
- Opt-in for anything personal or permission-backed: clipboard, downloads, meetings, approvals, GitHub,
  battery alerts.
- Nothing opens itself because of context; notifications are previews and never take keyboard focus.
