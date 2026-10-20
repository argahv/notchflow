# Integration inventory

What each external interface actually provides, verified against official documentation on 2026-10-20, and how NotchFlow uses it. Nothing here relies on private APIs, terminal scraping or simulated keystrokes.

## Claude Code — command hooks

Source: code.claude.com/docs/en/hooks (installed: 2.1.302).

- Delivery: JSON on stdin to a command hook; matching hooks run in parallel; default timeout 600 s, configurable per handler (`timeout`, seconds).
- Common fields: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name` (+ `prompt_id`, `agent_id`/`agent_type` inside subagents).
- Events used:
  - `SessionStart` — `source` (`startup`, `resume`, `clear`, `compact`, `fork`), optional `model`, `session_title`.
  - `UserPromptSubmit` — `prompt` (user content: **never stored or shown**).
  - `PreToolUse` / `PostToolUse` / `PostToolUseFailure` — `tool_name`, `tool_input`, `tool_use_id` (`tool_input` may contain secrets: only the tool **name** is used, except in a pending permission request).
  - `PermissionRequest` — `tool_name`, `tool_input`, optional `permission_suggestions`. A hook may answer with `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` or `behavior: "deny"` (+ `message`, `interrupt`). No output / timeout → no decision; the normal flow continues. The docs do not state whether the terminal dialog waits for the hook, so NotchFlow's wait is short and opt-in.
  - `Notification` — `message`, optional `title`, `notification_type` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`, …).
  - `Stop` — `stop_hook_active`, `last_assistant_message` (assistant content: **never stored or shown**). Stop means the turn finished, not the project.
  - `StopFailure` — turn ended on an API error. `SessionEnd` — session ended.
- No hook provides: a stable request identifier, the git branch, or a way to answer a dialog after it is shown. NotchFlow's hook generates its own request id and nonce and reads the branch from `.git/HEAD`.

## OpenAI Codex — lifecycle hooks and `notify`

Source: learn.chatgpt.com/docs/hooks and …/config-file/config-advanced. Codex CLI is not installed on this Mac, so this adapter is covered by fixture tests only.

- Hooks: JSON on stdin; events `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, `SubagentStart/Stop`, `PreCompact/PostCompact`, `Interrupt`. Common fields `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`; turn events add `turn_id`. `PermissionRequest` accepts the same `decision.behavior` allow/deny output; "any deny wins". Non-managed hooks must be trusted in Codex before they run.
- `notify`: a program receiving one JSON **argument**; currently only `type: "agent-turn-complete"` with `thread-id`, `turn-id`, `cwd`, `input-messages`, `last-assistant-message`. NotchFlow uses only `type`, ids and `cwd`.

## GitHub Actions — REST API

- Read: `GET /repos/{owner}/{repo}/actions/runs`, `…/runs/{id}/jobs`. Conditional requests (`If-None-Match`) return 304 without consuming rate limit. Unauthenticated: public repositories, 60 requests/hour. Token (fine-grained, *Actions: read*): private repositories, 5 000/hour.
- No webhooks: they need a public endpoint, which a local app does not have. NotchFlow polls with ETags, adaptive intervals and backoff.
- Write actions (re-run) are not offered: they need write permission and are outside the read-only scope.

## macOS platform

| Need | API | Permission |
| --- | --- | --- |
| Frontmost app (context) | `NSWorkspace.didActivateApplicationNotification` | None |
| Clipboard | `NSPasteboard.changeCount` — there is no change notification, so it is polled (0.75 s) only while clipboard history is enabled | None |
| Downloads | `DispatchSource` directory watch of the chosen folder | Files & Folders (Downloads) prompt on first access |
| Calendar / meetings | EventKit (`EKEventStoreChanged`) | Calendar (already explicit in Tools) |
| Audio output | Core Audio `kAudioHardwarePropertyDefaultOutputDevice`, property listeners | None |
| Power | IOKit power-source notifications, `ProcessInfo.isLowPowerModeEnabled` | None |
| Media | Music/Spotify distributed notifications; AppleScript only while Music is visible | Automation, on first command |
| Secrets | Keychain generic password | None |

## Not supported (and not faked)

- Answering a Claude/Codex prompt after its terminal dialog is shown, or typing into a terminal.
- Opening the exact terminal tab of a session: NotchFlow can bring the session's terminal application forward (from `TERM_PROGRAM`), not a specific tab.
- Universal browser download progress: only browser temp files (`.crdownload`, `.part`, `.download`) signal "in progress", with no percentage.
- Password detection on the clipboard: only explicit concealed/transient pasteboard markers and excluded apps are honored.
