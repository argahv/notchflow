#!/usr/bin/env python3
"""NotchFlow local event publisher. Python 3.9+, standard library only."""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import uuid

PHASES = ("started", "progress", "waiting", "completed", "failed", "cancelled")
ROOT = Path.home() / "Library/Application Support/NotchFlow"

def iso(value):
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def validate(event):
    from urllib.parse import urlsplit
    if event.get("version") != 1 or event.get("phase") not in PHASES:
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
    timestamp = dt.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
    now = dt.datetime.now(dt.timezone.utc)
    if timestamp.tzinfo is None or timestamp > now + dt.timedelta(minutes=5) or timestamp < now - dt.timedelta(days=7):
        raise ValueError("Timestamp outside accepted window")
    if "expiresAt" in event:
        expiry = dt.datetime.fromisoformat(event["expiresAt"].replace("Z", "+00:00"))
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
    args = parser.parse_args(argv)
    try:
        if args.command == "claude-hook":
            hook(args); return 0
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
