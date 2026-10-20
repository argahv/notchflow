# Security and privacy of integrations

NotchFlow is local-first. It has no account, telemetry, analytics or remote service of its own, and opens no
listening sockets. The only network requests it makes are to `api.github.com`, for repositories you add, and
only when GitHub Actions is on.

## Trust boundary

Everything below trusts processes that run as **your macOS user**. Files are owner-only (`0700`
directories, `0600` files, written atomically, symlinks refused), so other users can't read or inject
anything. A process already running as you could write events or answers, but it could also act as you
directly. NotchFlow doesn't claim to defend against that.

## Data inventory

| Data | Where | Kept | Notes |
|---|---|---|---|
| Activity History | `~/Library/Application Support/NotchFlow/activities.json` | 200 records; retention setting (default 30 days) | `historySafe`: no pending requests, no sensitive summaries |
| Event inbox | `…/inbox/*.json` | Until ingested; rejects moved to `.rejected` for 24 h | 16 KiB cap, owner and type checked |
| Approval opt-in | `…/agent-approvals.json` | While the setting is on | `{enabled, pid, wait}` only |
| Approval answers | `…/responses/<id>.json` | Consumed by the hook; swept after 15 min | `{requestId, nonce, decision, timestamp}` |
| Notes, to-dos, shelf | SwiftData store in the same folder | Until deleted | Shelf keeps file references, not copies |
| Clipboard history | Memory only | Retention setting (1 h–1 week), 40 items, gone on quit | Off by default |
| GitHub token | Login Keychain, this device only | Until removed | Sent only to `api.github.com`; never logged or shown again |
| Preferences | `UserDefaults` | — | Repositories you follow; no secrets |

## Agent hooks

- Only documented hook fields are read. `prompt`, `last_assistant_message`, `tool_input`,
  `tool_response` and `transcript_path` are never published. The exception is a pending permission
  request's display description, which is marked sensitive, kept in memory, and dropped from History.
- Nothing received is executed. Commands in requests are shown as text only. The CLI's `run` passes
  arguments without a shell.
- Permission answers use the documented `PermissionRequest` decision output, a 128-bit request id and
  nonce compared in constant time, single-use response files, and a short capped wait. With no answer the
  hook prints nothing, so the agent's own prompt decides. NotchFlow never types into a terminal.
- NotchFlow never edits `~/.claude/settings.json`, `~/.codex/*` or other agent configuration. Settings only
  copies configuration to the pasteboard.

Details: [architecture/agent-integrations.md](../architecture/agent-integrations.md).

## Clipboard

Off by default. Text only, memory only. Copies are skipped when they come from password managers
(1Password, Bitwarden, Keychain Access, Passwords, LastPass, Dashlane, KeePassXC, Enpass), carry
nspasteboard.org concealed, transient or auto-generated markers, or look like a secret (token formats,
private keys, JWTs, `password=` assignments, long random-looking strings). **That last check is best effort:
it can miss secrets and can flag harmless text.** NotchFlow only reads the pasteboard's change count each
second until something changes. "Copy" puts an item back on the clipboard and never pastes or sends
keystrokes.

## Actions and links

Event actions accept `https`, `http` (with a host), `file` and `vscode` URLs, and run only on a click.
GitHub actions only follow `https://github.com/`. Meeting Join only offers HTTPS links on known meeting
hosts. Downloaded files are revealed in Finder, never opened.

## Permissions

Asked for only when the feature that needs it is turned on: Calendar and Reminders (Tools › Calendar,
meeting reminders), Camera (Mirror), the Downloads folder (Download Center), Apple Events for Music and
Spotify (Music), and Screen Recording (Ultra visuals only). It never needs Accessibility or the microphone.
Settings › Permissions shows the current status of each.

## Tokens and logging

Tokens live only in the Keychain. They're never written to disk, `UserDefaults`, History, logs or
notifications. Provider errors report HTTP status classes, not response bodies or headers.
