# Agent integrations

NotchFlow shows Claude Code and Codex sessions from their **documented hook interfaces** and can answer a
permission request through the **documented `PermissionRequest` decision output**. It never types into a
terminal, never reads transcripts, and never edits agent configuration.

Sources (checked 2026-10-20): Claude Code hooks reference, code.claude.com/docs/en/hooks (Claude Code
2.1.302 is installed on the development Mac); Codex hooks, learn.chatgpt.com/docs/hooks, and Codex
`notify` in the advanced configuration page. Codex is not installed on the development Mac, so the Codex
paths are covered by fixture tests only.

## Pieces

| Piece | Where | Role |
|---|---|---|
| Hook adapter | `Scripts/notchflow.py agent-hook --provider claude\|codex` (bundled in the app's Resources) | Reads one hook payload on stdin, publishes a contract v2 event to the owner-only inbox, and for an opted-in `PermissionRequest` waits briefly for an answer. |
| Codex notify | `Scripts/notchflow.py codex-notify '<json>'` | Completion-only alternative: `agent-turn-complete` → Finished. Use it or the Codex hooks, not both (the thread id and the hook `session_id` aren't documented to be the same, so both together could show two cards). |
| Inbox | `Features/EventBridge.swift` | Owner-only file spool; each drain is applied oldest first (millisecond timestamps keep a burst in order). |
| Approvals | `Features/AgentApprovals.swift` | Presence file and single-use responses (below). |
| UI | `Surfaces/ActivitySurface.swift` | Agent rows, project sections in the Agents filter, the permission prompt, "Open ‹host app›". |
| Setup | `Features/HookSetup.swift`, Settings › Agents | Copies hook configuration to the pasteboard for the user to merge. |

The legacy `claude-hook` subcommand is unchanged for existing installs.

## Event mapping

One card per session (`source` + `session_id`). Project = last path component of `cwd`; branch from
`.git/HEAD` (worktrees via `gitdir:`/`commondir`); repository from the `origin` URL when it is on github.com.
The adapter reads those files and never runs `git`. Host app = `__CFBundleIdentifier` (the app that launched
the session's shell), falling back to `TERM_PROGRAM`.

| Hook event | State | Agent state (label) |
|---|---|---|
| `SessionStart` | queued (expires in 15 min) | idle ("Ready") |
| `UserPromptSubmit` | running | working ("Working") |
| `PreToolUse` | running | executingTool ("Running ‹tool›") |
| `PostToolUse`, `PostToolUseFailure` | running | working |
| `PermissionRequest` | needsInput | awaitingAuthorization ("Needs permission · ‹tool›") |
| `Notification` `permission_prompt` | needsInput | awaitingAuthorization |
| `Notification` `idle_prompt` | waiting | waitingForUser ("Waiting for you") |
| `Notification` `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` | needsInput | waitingForUser |
| `Stop` | completed | completed ("Finished"): the **turn** ended, not the session |
| `StopFailure` | failed | failed |
| `Interrupt` (Codex) | waiting | waitingForUser |
| `SessionEnd` | cancelled | disconnected ("Ended") |
| anything else | ignored | |

Live states expire after 30 minutes without a newer event, so a session whose terminal was closed doesn't
stay "Working" forever. There is no fabricated progress: agent rows show a spinner, never a percentage.

**Never forwarded:** `prompt`, `last_assistant_message`, `tool_input`, `tool_response`, `transcript_path`.
The one exception is a pending permission request's description (the command, file path, URL or pattern,
whitespace-collapsed, at most 400 characters). It is marked `sensitive`, kept in memory, and dropped before
anything is written to History (`ActivityEvent.historySafe`). It sits in the inbox file only for the moment
between the hook writing it and the app ingesting it.

## Answering a permission request

Off by default (Settings › Agents › "Answer permission requests from the notch").

1. **Opt-in.** The app writes `~/Library/Application Support/NotchFlow/agent-approvals.json`
   (`0600`, atomic): `{"enabled": true, "pid": <app pid>, "wait": <seconds>}`. It's removed when the
   setting is turned off or the app quits normally. A hook only waits if the file is a private regular file
   owned by the user and that pid is alive, so a crashed app never makes an agent wait.
2. **Request.** The hook generates a 128-bit request id and a 128-bit nonce, publishes `needsInput` with
   `request {id, nonce, tool, detail, expiresAt}`, and polls `responses/<id>.json` every 0.2 s until the
   wait (default 25 s, 10–55 s) runs out.
3. **Answer.** "Allow once" takes two presses (it disarms after 4 s); "Deny" takes one. The app writes
   `{"requestId", "nonce", "decision", "timestamp"}` to `responses/<id>.json` (`0600`, atomic) and withdraws
   the request from the card at once so it can't be answered twice. The hook accepts it only if the id and
   nonce match (constant-time compare), deletes it, prints the documented output and exits 0:
   `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}`
   or `"behavior": "deny", "message": "Denied from NotchFlow."`.
4. **No answer.** The hook prints nothing, which both products document as "no decision": the normal
   permission flow continues, so the agent's own prompt decides. The card stops offering buttons and shows
   "Open ‹host app›" instead. Claude Code documents that sessions which can't show a prompt deny a tool call
   when no hook decides; that's unchanged by NotchFlow.

Neither product documents whether its dialog is visible while a `PermissionRequest` hook is still running
(Claude Code says the hook runs "when Claude Code is about to ask you"). That is why the wait is short and
capped, and why the `PermissionRequest` hook is configured as synchronous with `timeout = wait + 5`. A
background (`async`) hook's answer would arrive too late to decide.

**Trust boundary.** The files are owner-only, and the nonce stops a stale or replayed response from
answering a different request. Any process running as the same macOS user could still read the inbox and
write a response, but such a process can already act as that user directly. NotchFlow doesn't protect
against code that already runs as you.

**Open ‹host app›** brings the session's app forward (`NSWorkspace.openApplication`) and closes the
workspace without handing focus back. It can't select a tab or window, and the label doesn't claim to.

## Setup

Settings › Agents has three Copy buttons; nothing is installed automatically.

- **Claude Code:** merge into `~/.claude/settings.json`. Status hooks use `"async": true` (documented:
  runs in the background without blocking); `PermissionRequest` is synchronous.
- **Codex hooks:** merge into `~/.codex/hooks.json`, then review and trust them with `/hooks` (Codex skips
  untrusted or changed hooks). `Interrupt` and `SessionEnd` use the documented 3-second maximum.
- **Codex notify:** one `notify = [...]` line for `config.toml`.

The commands point at the copy of `notchflow.py` inside the app bundle. Moving the app means copying them
again.

## Verified

- Fixture tests (`Tests/test_bridge.py`, `AgentHookTests`): every mapping row, ignored events, privacy
  (prompt, assistant text, tool input and transcript path never published), git context including worktrees,
  presence-file checks (permissions, opt-out, dead pid, wait clamp), allow, deny, wrong nonce, timeout,
  no-opt-in path doesn't wait, terminal identity, Codex notify, and v2 validation parity with Swift.
- End to end on the development Mac, with real processes but simulated payloads: the bundled script run
  through `/bin/sh -c` exactly as configured, waiting while the app showed the prompt, then printing the
  allow or deny JSON after the app answered. The timeout printed nothing after the configured wait and
  withdrew the request; a late answer was refused and wrote nothing.
- **Not yet verified:** a live Claude Code or Codex session driving these hooks. That needs the user to
  install the hooks in their own settings.
