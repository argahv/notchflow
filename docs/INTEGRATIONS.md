# Local integrations

## Event contract v1

One UTF-8 JSON object per atomically written file, at most 16 KiB:

```json
{
  "version": 1,
  "source": "claude-code",
  "activityId": "session-42",
  "phase": "waiting",
  "title": "Claude needs your attention",
  "summary": "Choose how to handle a failing test.",
  "timestamp": "2026-10-20T14:00:00Z",
  "expiresAt": "2026-10-20T15:00:00Z",
  "actionURL": "vscode://file/Users/you/projects/portfolio"
}
```

The sample dates are illustrative. Publishers must send the current timestamp.

Required: `version`, `source`, `activityId`, `phase`, `title`, `timestamp`. Optional: `summary`, `progress` from 0 to 1, `expiresAt`, `actionURL`. Use whole-second ISO 8601 UTC dates (`…Z`) for Swift decoder compatibility.

Phases: `started`, `progress`, `waiting`, `completed`, `failed`, `cancelled`. The key is `(source, activityId)`. Newer updates replace the same activity; older timestamps are ignored. Terminal events remain in history. Nonterminal events without explicit expiry become stale after an hour. Publishers should heartbeat long-running work. Waiting outranks background progress. Failed and completed events can request a temporary preview but don't stay in the active queue.

The history retains 200 latest activity records. This is latest-state-per-task history, not a complete audit log of every event. Snooze hides an active task for ten minutes; it does not create an OS notification.

Actions permit only HTTP(S), file and VS Code URLs. Explicit clicks are required. There is no remote shell command field. Do not publish secrets in titles, summaries or URLs. The privacy switch conceals UI but does not encrypt on-disk history.

## Claude Code and Codex

**Current adapter:** `notchflow.py agent-hook --provider claude|codex`, with tool state, project and branch, and optional answers to permission requests. Copy its configuration from Settings › Agents. See [architecture/agent-integrations.md](architecture/agent-integrations.md). The `claude-hook` setup below still works for existing installs.

### Legacy `claude-hook`

This is a command-hook adapter, not a plugin that controls Claude. Copy the actual absolute path of `Scripts/notchflow.py` into the command below. Merge these entries into your existing Claude Code settings; do not overwrite unrelated hooks.

```json
{
  "hooks": {
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "python3 '/Users/YOU/projects/notchflow/Scripts/notchflow.py' claude-hook", "timeout": 5}]}
    ],
    "Notification": [
      {"matcher": "permission_prompt|idle_prompt", "hooks": [{"type": "command", "command": "python3 '/Users/YOU/projects/notchflow/Scripts/notchflow.py' claude-hook", "timeout": 5}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "python3 '/Users/YOU/projects/notchflow/Scripts/notchflow.py' claude-hook", "timeout": 5}]}
    ]
  }
}
```

The adapter reads `hook_event_name`, `notification_type`, `session_id`, `cwd` and optional `message` from stdin. SessionStart means the session began; Notification means a permission or idle request; Stop means **the current turn finished**, not that a project is complete. Session identifiers deduplicate updates. There is no fabricated session-resume link: use a publisher-supplied validated URL for integrations with real deep links.

The hook adapter is covered by fixture tests. Actual Claude hooks on a Mac still need integration verification. It does not heartbeat the entire Claude session; the CLI command wrapper does heartbeat its subprocess.

Official reference: https://code.claude.com/docs/en/hooks (checked 2026-10-20).

## Other tools

Wrap local commands with `run`, or publish your own lifecycle updates with `emit`. GitHub Actions, remote CI, MCP and other agent runtimes are not connected automatically. No GitHub tokens are requested or stored by this app.

## Inbox behavior

- Root and inbox directories use mode 0700. Publisher files use 0600.
- CLI rejects a symbolic-link inbox and incorrect ownership. Receiver checks regular file, owner, size and event validity.
- Invalid files are renamed `.rejected` and discarded after one day on a subsequent drain.
- CLI limits pending JSON files to 500; launch the app to drain a backlog.
- A directory-change watcher drains events without polling a network port.
- Disabling the bridge stops reading. Queued files remain local until re-enabled or removed.
- This design assumes the user's account is trusted. It is not hardened against an actively malicious process with the same user privileges.
