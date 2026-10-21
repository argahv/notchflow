#!/usr/bin/env python3
"""NotchFlow local event publisher. Python 3.9+, standard library only."""
import argparse
import datetime as dt
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import uuid

PHASES = ("started", "progress", "waiting", "completed", "failed", "cancelled")
# Contract v2 state -> the v1 phase it implies (mirrors ActivityState.phase).
STATES = {"queued": "started", "starting": "started", "running": "progress", "paused": "progress",
          "unknown": "progress", "waiting": "waiting", "needsInput": "waiting", "completed": "completed",
          "failed": "failed", "cancelled": "cancelled"}
TERMINAL = ("completed", "failed", "cancelled")
CATEGORIES = ("task", "agent", "build", "deploy", "ci", "download", "timer", "meeting", "system")
AGENT_STATES = ("idle", "starting", "working", "executingTool", "waitingForUser", "awaitingAuthorization",
                "completed", "failed", "disconnected", "unknown")
V2_FIELDS = ("category", "state", "project", "branch", "groupKey", "parentId", "sensitive", "agent", "request")
PROVIDERS = {"claude": ("claude-code", "Claude Code"), "codex": ("codex", "Codex")}
APPROVAL_WAIT = (5, 55, 25)  # seconds: minimum, maximum, default
ROOT = Path.home() / "Library/Application Support/NotchFlow"

def iso(value):
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def iso_ms(value):
    """Millisecond timestamps keep a burst of hook events in order."""
    return value.astimezone(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

def is_token(value, limit):
    return isinstance(value, str) and 0 < len(value) <= limit and all(c.isalnum() or c in "-._" for c in value)

def is_hex(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value) is not None

def parse_time(value):
    if not isinstance(value, str):
        raise ValueError("Timestamps must be ISO 8601 strings")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamps need a time zone")
    return parsed

def validate_v2(event):
    """Mirrors ActivityEvent.validate for the version 2 fields."""
    state = event.get("state")
    if state not in STATES or STATES[state] != event.get("phase"):
        raise ValueError("State contradicts phase")
    if "category" in event and event["category"] not in CATEGORIES:
        raise ValueError("Unknown category")
    for key, limit in (("project", 80), ("branch", 120), ("groupKey", 128), ("parentId", 128)):
        if key in event and (not isinstance(event[key], str) or not 0 < len(event[key]) <= limit):
            raise ValueError("Invalid " + key)
    if "sensitive" in event and not isinstance(event["sensitive"], bool):
        raise ValueError("Invalid sensitive flag")
    agent = event.get("agent")
    if agent is not None:
        if not isinstance(agent, dict) or not is_token(agent.get("provider"), 32):
            raise ValueError("Invalid agent metadata")
        session = agent.get("sessionId")
        if not isinstance(session, str) or not 0 < len(session) <= 128 or agent.get("state", "idle") not in AGENT_STATES:
            raise ValueError("Invalid agent metadata")
        for key in ("tool", "terminal"):
            if key in agent and (not isinstance(agent[key], str) or len(agent[key]) > 64):
                raise ValueError("Invalid agent metadata")
        repository = agent.get("repository")
        if repository is not None and not (isinstance(repository, str) and len(repository.split("/")) == 2
                                           and all(is_token(part, 100) for part in repository.split("/"))):
            raise ValueError("Invalid repository")
    request = event.get("request")
    if request is not None:
        if not isinstance(request, dict) or not is_hex(request.get("id")) or not is_hex(request.get("nonce")) \
                or request.get("kind") != "permission" or not isinstance(request.get("tool"), str) \
                or not 0 < len(request["tool"]) <= 64 or not isinstance(request.get("detail", ""), str) \
                or len(request.get("detail", "")) > 400:
            raise ValueError("Invalid request")
        timestamp, expiry = parse_time(event.get("timestamp")), parse_time(request.get("expiresAt"))
        if not timestamp < expiry <= timestamp + dt.timedelta(minutes=10):
            raise ValueError("Invalid request expiry")
        if state != "needsInput" or agent is None:
            raise ValueError("Requests belong to agents that need input")

def validate(event):
    from urllib.parse import urlsplit
    version = event.get("version")
    if version == 1:
        if event.get("phase") not in PHASES or any(key in event for key in V2_FIELDS):
            raise ValueError("Unsupported event version or phase")
    elif version == 2:
        validate_v2(event)
    else:
        raise ValueError("Unsupported event version or phase")
    for key, limit in (("source", 64), ("activityId", 128), ("title", 160)):
        value = event.get(key)
        if not isinstance(value, str) or not 0 < len(value) <= limit:
            raise ValueError("Invalid " + key)
    if "summary" in event and (not isinstance(event["summary"], str) or len(event["summary"]) > 2000):
        raise ValueError("Summary must contain at most 2000 characters")
    progress = event.get("progress")
    if progress is not None and (isinstance(progress, bool) or not isinstance(progress, (int, float)) or not math.isfinite(progress) or not 0 <= progress <= 1):
        raise ValueError("Progress must be between zero and one")
    if "actionURL" in event:
        url = urlsplit(event["actionURL"])
        if len(event["actionURL"]) > 4096 or url.scheme.lower() not in ("https", "http", "file", "vscode"):
            raise ValueError("Unsupported action URL")
        if url.scheme.lower() in ("https", "http") and not url.hostname:
            raise ValueError("Web actions require a host")
    timestamp = parse_time(event.get("timestamp"))
    now = dt.datetime.now(dt.timezone.utc)
    if timestamp > now + dt.timedelta(minutes=5) or timestamp < now - dt.timedelta(days=7):
        raise ValueError("Timestamp outside accepted window")
    if "expiresAt" in event:
        expiry = parse_time(event["expiresAt"])
        if expiry <= timestamp:
            raise ValueError("Expiry must follow timestamp")
    payload = json.dumps(event, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(payload) > 16384:
        raise ValueError("Event exceeds 16 KiB")
    return payload

def secure_directory(path):
    if path.is_symlink():
        raise ValueError("Refusing symbolic link directory: " + str(path))
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("Inbox must be owned by the current user")
    path.chmod(0o700)

def publish(event, root=ROOT):
    payload = validate(event)
    secure_directory(root)
    inbox = root / "inbox"
    secure_directory(inbox)
    if sum(1 for _ in inbox.glob("*.json")) >= 500:
        raise ValueError("Event inbox is full; launch NotchFlow before publishing more events")
    fd, name = tempfile.mkstemp(prefix=".event-", suffix=".tmp", dir=inbox)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        destination = inbox / (uuid.uuid4().hex + ".json")
        os.replace(name, destination)
        return destination
    finally:
        if os.path.exists(name):
            os.unlink(name)

def event_for(args, phase, summary=None):
    now = dt.datetime.now(dt.timezone.utc)
    event = {"version": 1, "source": args.source, "activityId": args.id,
             "phase": phase, "title": args.title, "timestamp": iso(now)}
    if summary:
        event["summary"] = summary
    if getattr(args, "action_url", None):
        event["actionURL"] = args.action_url
    if getattr(args, "progress", None) is not None:
        event["progress"] = args.progress
    if not phase in ("completed", "failed", "cancelled"):
        event["expiresAt"] = iso(now + dt.timedelta(seconds=getattr(args, "ttl", 3600)))
    return event

def hook(args):
    """Claude Code command hook: read official hook JSON from stdin, never evaluate it."""
    payload = json.load(sys.stdin)
    event_name = payload.get("hook_event_name", "")
    phase = {"Stop": "completed", "Notification": "waiting", "SessionStart": "started"}.get(event_name)
    if not phase:
        return
    # Only permission/idle notifications are requests for user attention.
    if event_name == "Notification" and payload.get("notification_type") not in ("permission_prompt", "idle_prompt"):
        return
    cwd = payload.get("cwd") or "workspace"
    args.source = "claude-code"
    args.id = str(payload.get("session_id") or "unknown")[:128]
    args.title = {"Stop": "Claude turn finished", "Notification": "Claude needs your attention", "SessionStart": "Claude session started"}[event_name]
    summary = str(payload.get("message") or Path(cwd).name)[:2000]
    # Stop means the current turn finished, not that the entire project is complete.
    publish(event_for(args, phase, summary))

# MARK: Agent hooks (Claude Code and Codex). Documented hook payloads only; prompts, assistant text and
# tool input are never forwarded, except a short display-only description of a pending permission
# request, which is marked sensitive and never written to History.

def read_small(path, limit=65536):
    try:
        with open(path, "rb") as handle:
            return handle.read(limit).decode("utf-8", "replace")
    except OSError:
        return None

def github_repository(config):
    """owner/name of the `origin` remote when it is on github.com."""
    section, url = None, None
    for line in config.splitlines():
        line = line.strip()
        if line.startswith("["):
            section = line
        elif section == '[remote "origin"]' and line.replace(" ", "").startswith("url="):
            url = line.split("=", 1)[1].strip()
            break
    match = re.search(r"github\.com[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$", url or "")
    if not match or not all(is_token(part, 100) for part in match.groups()):
        return None
    return "/".join(match.groups())

def git_context(cwd):
    """(branch, GitHub owner/name) for a working directory, read from .git files. Never runs git."""
    try:
        directory = Path(cwd).resolve()
    except (OSError, RuntimeError, ValueError):
        return None, None
    gitdir = None
    for candidate in (directory, *directory.parents):
        marker = candidate / ".git"
        if marker.is_dir():
            gitdir = marker
            break
        if marker.is_file():  # worktree or submodule: "gitdir: <path>"
            text = read_small(marker) or ""
            if text.startswith("gitdir:"):
                gitdir = (candidate / text[len("gitdir:"):].strip()).resolve()
            break
    if gitdir is None:
        return None, None
    head = (read_small(gitdir / "HEAD") or "").strip()
    branch = head[len("ref: refs/heads/"):][:120] if head.startswith("ref: refs/heads/") else None
    common = gitdir
    commondir = read_small(gitdir / "commondir")
    if commondir:
        common = (gitdir / commondir.strip()).resolve()
    return branch or None, github_repository(read_small(common / "config") or "")

TEST_RUNNERS = ("swift test", "npm test", "npm run test", "pnpm test", "pnpm run test", "yarn test", "bun test",
                "npx jest", "npx vitest", "npx playwright test", "jest", "vitest", "pytest", "python -m pytest",
                "python3 -m pytest", "python -m unittest", "python3 -m unittest", "go test", "cargo test", "rspec",
                "bundle exec rspec", "rails test", "mvn test", "gradle test", "./gradlew test", "phpunit",
                "vendor/bin/phpunit", "dotnet test", "mix test", "make test", "ctest")

def runs_tests(tool_input):
    """Whether a shell tool call runs a test suite, judged where each command starts. Only this yes or
    no leaves the hook, as the tool label "Tests"; the command itself never does."""
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if isinstance(command, list):
        command = " ".join(str(part) for part in command)
    if not isinstance(command, str):
        return False
    for segment in re.split(r"&&|\|\||[;|\n]", command[:4000]):
        words = segment.strip().split()
        while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=\S*", words[0]):  # FOO=1 swift test
            words.pop(0)
        if words and words[0] in ("sudo", "time", "exec"):
            words.pop(0)
        if words and words[0] == "xcodebuild" and any(word in ("test", "test-without-building") for word in words[1:]):
            return True
        text = " ".join(words)
        if any(text == runner or text.startswith(runner + " ") for runner in TEST_RUNNERS):
            return True
    return False

def agent_state_for(name, payload):
    """(state, agent state, tool) for a documented hook event, or None to ignore it."""
    tool = payload.get("tool_name")
    tool = tool[:64] if isinstance(tool, str) and tool else None
    if name == "SessionStart":
        return "queued", "idle", None
    if name == "UserPromptSubmit":
        return "running", "working", None
    if name == "PreToolUse":
        return "running", "executingTool", "Tests" if runs_tests(payload.get("tool_input")) else tool
    if name in ("PostToolUse", "PostToolUseFailure"):
        return "running", "working", None
    if name == "PermissionRequest":
        return "needsInput", "awaitingAuthorization", tool
    if name == "Notification":
        kind = payload.get("notification_type")
        if kind == "permission_prompt":
            return "needsInput", "awaitingAuthorization", None
        if kind == "idle_prompt":
            return "waiting", "waitingForUser", None
        if kind in ("elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"):
            return "needsInput", "waitingForUser", None
        return None
    if name == "Stop":  # the turn finished, not necessarily the session
        return "completed", "completed", None
    if name == "StopFailure":
        return "failed", "failed", None
    if name == "Interrupt":  # Codex: the user interrupted the turn; the session waits for them
        return "waiting", "waitingForUser", None
    if name == "SessionEnd":
        return "cancelled", "disconnected", None
    return None

def agent_event(provider, payload, state, agent_state, tool=None, request=None, ttl=1800):
    source, title = PROVIDERS[provider]
    session = payload.get("session_id")
    session = session[:128] if isinstance(session, str) and session else "unknown"
    now = dt.datetime.now(dt.timezone.utc)
    event = {"version": 2, "source": source, "activityId": session, "phase": STATES[state], "state": state,
             "category": "agent", "title": title, "timestamp": iso_ms(now)}
    agent = {"provider": source, "sessionId": session, "state": agent_state}
    if tool:
        agent["tool"] = tool
    # The app hosting the session, so NotchFlow can bring it forward. macOS passes the launching app's
    # bundle identifier to child processes; TERM_PROGRAM is the fallback (it can't tell VS Code forks apart).
    bundle = os.environ.get("__CFBundleIdentifier", "")
    terminal = bundle if is_token(bundle, 64) and "." in bundle else os.environ.get("TERM_PROGRAM", "")
    if is_token(terminal, 64):
        agent["terminal"] = terminal
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd:
        project = Path(cwd).name[:80]
        if project:
            event["project"] = event["groupKey"] = project
        branch, repository = git_context(cwd)
        if branch:
            event["branch"] = branch
        if repository:
            agent["repository"] = repository
    event["agent"] = agent
    if state not in TERMINAL:
        event["expiresAt"] = iso_ms(now + dt.timedelta(seconds=ttl))
    if request:
        event["request"] = request
        event["sensitive"] = True
    return event

def approvals_config(root):
    """The app's opt-in presence file, or None when approvals are off or NotchFlow isn't running."""
    path = root / "agent-approvals.json"
    try:
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() \
                or metadata.st_mode & 0o077 or metadata.st_size > 4096:
            return None
        config = json.loads(path.read_text())
        pid = config.get("pid")
        if config.get("enabled") is not True or isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
            return None
        os.kill(pid, 0)  # raises when no such process (or not ours)
    except (OSError, ValueError, AttributeError):
        return None
    low, high, default = APPROVAL_WAIT
    wait = config.get("wait")
    if isinstance(wait, bool) or not isinstance(wait, (int, float)) or not low <= wait <= high:
        wait = default
    return {"wait": float(wait)}

def permission_detail(tool_input):
    """What the agent wants to do, for display only. Never evaluated."""
    if not isinstance(tool_input, dict):
        return None
    for key in ("command", "file_path", "path", "url", "pattern", "description"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return " ".join(value.split())[:400]
    return None

def read_decision(path, request):
    """Read an owner-only response exactly once, without following symlinks."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return None
    try:
        with os.fdopen(fd, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() \
                    or metadata.st_mode & 0o077 or metadata.st_size > 4096:
                return None
            response = json.loads(stream.read(4097).decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    finally:
        try:
            path.unlink()  # response is consumed even when invalid
        except OSError:
            pass
    if not isinstance(response, dict) or response.get("requestId") != request["id"] \
            or not hmac.compare_digest(str(response.get("nonce", "")), request["nonce"]):
        return None
    decision = response.get("decision")
    return decision if decision in ("allow", "deny") else None

def await_decision(root, request, wait, poll=0.2):
    path = root / "responses" / (request["id"] + ".json")
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        decision = read_decision(path, request)
        if decision:
            return decision
        time.sleep(poll)
    return None

def decision_output(decision):
    """The documented PermissionRequest hook output (same shape for Claude Code and Codex)."""
    behavior = {"behavior": decision}
    if decision == "deny":
        behavior["message"] = "Denied from NotchFlow."
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": behavior}}

def answer_permission(provider, payload, tool, wait, root):
    now = dt.datetime.now(dt.timezone.utc)
    request = {"id": secrets.token_hex(16), "nonce": secrets.token_hex(16), "kind": "permission",
               "tool": tool or "tool", "expiresAt": iso_ms(now + dt.timedelta(seconds=wait))}
    detail = permission_detail(payload.get("tool_input"))
    if detail:
        request["detail"] = detail
    publish(agent_event(provider, payload, "needsInput", "awaitingAuthorization", tool, request=request))
    decision = await_decision(root, request, wait)
    if decision is None:
        # No answer in time: the agent's own prompt decides, and the card stops offering buttons.
        publish(agent_event(provider, payload, "needsInput", "awaitingAuthorization", tool))
        return 0
    print(json.dumps(decision_output(decision)))
    if decision == "allow":
        publish(agent_event(provider, payload, "running", "executingTool", tool))
    else:
        publish(agent_event(provider, payload, "running", "working"))
    return 0

def agent_hook(args):
    """Claude Code or Codex command hook: official hook JSON on stdin, never evaluated."""
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    name = payload.get("hook_event_name")
    mapped = agent_state_for(name, payload)
    if mapped is None:
        return 0
    state, agent_state, tool = mapped
    if name == "PermissionRequest":
        approvals = approvals_config(ROOT)
        if approvals:
            return answer_permission(args.provider, payload, tool, approvals["wait"], ROOT)
    publish(agent_event(args.provider, payload, state, agent_state, tool, ttl=900 if name == "SessionStart" else 1800))
    return 0

def codex_notify(args):
    """Codex `notify` program: one JSON argument; only agent-turn-complete is documented."""
    try:
        payload = json.loads(args.payload)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("type") != "agent-turn-complete":
        return 0
    publish(agent_event("codex", {"session_id": payload.get("thread-id"), "cwd": payload.get("cwd")}, "completed", "completed"))
    return 0

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("emit", "run"):
        child = sub.add_parser(name)
        child.add_argument("--source", default="terminal")
        child.add_argument("--id", default=uuid.uuid4().hex)
        child.add_argument("--title", required=True)
        child.add_argument("--action-url")
        child.add_argument("--ttl", type=int, default=3600)
        if name == "emit":
            child.add_argument("--phase", choices=PHASES, default="waiting")
            child.add_argument("--summary")
            child.add_argument("--progress", type=float)
        else:
            child.add_argument("arguments", nargs=argparse.REMAINDER)
    sub.add_parser("claude-hook")
    sub.add_parser("agent-hook").add_argument("--provider", choices=sorted(PROVIDERS), required=True)
    sub.add_parser("codex-notify").add_argument("payload")
    args = parser.parse_args(argv)
    try:
        if args.command == "claude-hook":
            hook(args); return 0
        if args.command == "agent-hook":
            return agent_hook(args)
        if args.command == "codex-notify":
            return codex_notify(args)
        if args.ttl < 1:
            raise ValueError("TTL must be positive")
        if args.command == "emit":
            publish(event_for(args, args.phase, args.summary)); return 0
        command = args.arguments
        if command and command[0] == "--": command = command[1:]
        if not command: raise ValueError("Provide a command after --")
        publish(event_for(args, "started"))
        try:
            process = subprocess.Popen(command)
            while True:
                try:
                    code = process.wait(timeout=min(30, max(1, args.ttl // 2)))
                    break
                except subprocess.TimeoutExpired:
                    publish(event_for(args, "progress"))
            phase = "completed" if code == 0 else "failed"
            publish(event_for(args, phase, "Exit status " + str(code)))
            return code if code >= 0 else 128 - code
        except KeyboardInterrupt:
            if 'process' in locals():
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            publish(event_for(args, "cancelled")); return 130
        except OSError as error:
            publish(event_for(args, "failed", str(error))); return 127
    except (ValueError, OSError, KeyError, TypeError) as error:
        print("notchflow: " + str(error), file=sys.stderr); return 1

if __name__ == "__main__":
    sys.exit(main())
