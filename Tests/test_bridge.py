import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/notchflow.py"
spec = importlib.util.spec_from_file_location("notchflow", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class BridgeTests(unittest.TestCase):
    def event(self, **changes):
        value = {"version": 1, "source": "build", "activityId": "test", "phase": "waiting", "title": "Review",
                 "timestamp": bridge.iso(dt.datetime.now(dt.timezone.utc))}
        value.update(changes); return value

    def test_atomic_publish_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "NotchFlow"
            path = bridge.publish(self.event(summary="नमस्ते"), root)
            self.assertEqual(json.loads(path.read_text())["summary"], "नमस्ते")
            self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(list(path.parent.glob("*.tmp")), [])

    def test_rejects_symlink_inbox(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "NotchFlow"; root.mkdir()
            (root / "inbox").symlink_to(Path(directory), target_is_directory=True)
            with self.assertRaises(ValueError): bridge.publish(self.event(), root)

    def test_rejects_malformed_and_unsafe_events(self):
        for changes in ({"progress": float("nan")}, {"progress": 2}, {"progress": True}, {"source": ""},
                        {"actionURL": "javascript:alert(1)"}, {"actionURL": "http:///missing"},
                        {"summary": "x" * 2001}, {"version": 2}, {"phase": "surprise"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError): bridge.validate(self.event(**changes))

    def test_rejects_stale_and_invalid_expiry(self):
        old = bridge.iso(dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=8))
        with self.assertRaises(ValueError): bridge.validate(self.event(timestamp=old))
        with self.assertRaises(ValueError): bridge.validate(self.event(expiresAt=old))

    def test_command_success_and_failure_are_published(self):
        for exit_code, phase in ((0, "completed"), (3, "failed")):
            events = []
            with patch.object(bridge, "publish", side_effect=lambda event: events.append(event)):
                result = bridge.main(["run", "--id", "build", "--title", "Tests", "--", sys.executable, "-c", f"raise SystemExit({exit_code})"])
            self.assertEqual(result, exit_code)
            self.assertEqual([event["phase"] for event in events], ["started", phase])
            self.assertEqual(events[0]["activityId"], events[1]["activityId"])

    def test_run_uses_arguments_without_shell_interpolation(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "literal.txt"
            literal = "$(touch should-never-exist); `id`"
            with patch.object(bridge, "publish"):
                result = bridge.main(["run", "--title", "Literal", "--", sys.executable, "-c",
                                      "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])", str(destination), literal])
            self.assertEqual(result, 0); self.assertEqual(destination.read_text(), literal)

    def test_claude_hook_maps_attention_and_turn_completion(self):
        for name, phase in (("Notification", "waiting"), ("Stop", "completed"), ("SessionStart", "started")):
            events = []
            payload = {"hook_event_name": name, "notification_type": "permission_prompt", "session_id": "abc", "cwd": "/tmp/portfolio"}
            with patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), patch.object(bridge, "publish", side_effect=events.append):
                self.assertEqual(bridge.main(["claude-hook"]), 0)
            self.assertEqual(events[0]["phase"], phase)
            self.assertEqual(events[0]["source"], "claude-code")

    def test_unrelated_hook_is_ignored(self):
        with patch.object(sys, "stdin", io.StringIO('{"hook_event_name":"PostToolUse"}')), patch.object(bridge, "publish") as publish:
            self.assertEqual(bridge.main(["claude-hook"]), 0)
            publish.assert_not_called()

    def test_cli_subprocess_smoke(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home)
            result = subprocess.run([sys.executable, str(SCRIPT), "emit", "--title", "Review", "--source", "smoke"], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            files = list((Path(home) / "Library/Application Support/NotchFlow/inbox").glob("*.json"))
            self.assertEqual(len(files), 1)

class AgentHookTests(unittest.TestCase):
    """Fixture payloads follow the documented Claude Code and Codex hook schemas."""
    def run_hook(self, payload, provider="claude", root=None):
        events, out = [], io.StringIO()
        def capture(event):
            bridge.validate(event)  # everything the adapter publishes must pass the contract
            events.append(json.loads(json.dumps(event)))
        with patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), patch.object(bridge, "publish", side_effect=capture), \
                patch.object(sys, "stdout", out), patch.object(bridge, "ROOT", root or Path(tempfile.gettempdir()) / "nf-missing"):
            self.assertEqual(bridge.main(["agent-hook", "--provider", provider]), 0)
        return events, out.getvalue()

    def base(self, name, **extra):
        value = {"hook_event_name": name, "session_id": "sess-1", "cwd": "/tmp/portfolio", "transcript_path": "/tmp/t.jsonl"}
        value.update(extra); return value

    def test_documented_events_map_to_states(self):
        cases = [
            (self.base("SessionStart", source="startup"), "queued", "idle", None),
            (self.base("UserPromptSubmit", prompt="secret plan"), "running", "working", None),
            (self.base("PreToolUse", tool_name="Bash", tool_input={"command": "ls"}), "running", "executingTool", "Bash"),
            (self.base("PostToolUse", tool_name="Bash", tool_response={}), "running", "working", None),
            (self.base("PostToolUseFailure", tool_name="Bash"), "running", "working", None),
            (self.base("PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf build"}), "needsInput", "awaitingAuthorization", "Bash"),
            (self.base("Notification", notification_type="permission_prompt", message="Claude needs permission"), "needsInput", "awaitingAuthorization", None),
            (self.base("Notification", notification_type="idle_prompt"), "waiting", "waitingForUser", None),
            (self.base("Notification", notification_type="elicitation_dialog"), "needsInput", "waitingForUser", None),
            (self.base("Notification", notification_type="elicitation_url_dialog"), "needsInput", "waitingForUser", None),
            (self.base("Stop", stop_hook_active=False, last_assistant_message="done"), "completed", "completed", None),
            (self.base("StopFailure"), "failed", "failed", None),
            (self.base("SessionEnd", reason="other"), "cancelled", "disconnected", None),
        ]
        for payload, state, agent_state, tool in cases:
            with self.subTest(event=payload["hook_event_name"], state=state):
                events, out = self.run_hook(payload)
                self.assertEqual(out, "", "only a permission decision may be printed")
                self.assertEqual(len(events), 1)
                event = events[0]
                self.assertEqual((event["state"], event["agent"]["state"], event["agent"].get("tool")), (state, agent_state, tool))
                self.assertEqual((event["source"], event["activityId"], event["project"]), ("claude-code", "sess-1", "portfolio"))
                self.assertNotIn("request", event, "no request without the app's opt-in")

    def test_unrelated_and_malformed_payloads_are_ignored(self):
        for payload in (self.base("SubagentStop"), self.base("PreCompact", trigger="auto"),
                        self.base("Notification", notification_type="auth_success"), ["not", "an", "object"]):
            with self.subTest(payload=payload):
                events, out = self.run_hook(payload)
                self.assertEqual((events, out), ([], ""))

    def test_prompts_assistant_text_and_tool_input_never_leave_the_hook(self):
        payloads = [self.base("UserPromptSubmit", prompt="PROMPT-SECRET"),
                    self.base("Stop", last_assistant_message="ASSISTANT-SECRET"),
                    self.base("PreToolUse", tool_name="Bash", tool_input={"command": "export TOKEN=INPUT-SECRET"})]
        for payload in payloads:
            events, _ = self.run_hook(payload)
            text = json.dumps(events)
            for secret in ("PROMPT-SECRET", "ASSISTANT-SECRET", "INPUT-SECRET", "t.jsonl"):
                self.assertNotIn(secret, text)

    def test_terminal_identity_prefers_the_hosting_app_bundle(self):
        payload = {"session_id": "s", "cwd": "/tmp/x"}
        with patch.dict(os.environ, {"__CFBundleIdentifier": "com.mitchellh.ghostty", "TERM_PROGRAM": "ghostty"}):
            self.assertEqual(bridge.agent_event("claude", payload, "running", "working")["agent"]["terminal"], "com.mitchellh.ghostty")
        with patch.dict(os.environ, {"__CFBundleIdentifier": "", "TERM_PROGRAM": "iTerm.app"}):
            self.assertEqual(bridge.agent_event("claude", payload, "running", "working")["agent"]["terminal"], "iTerm.app")
        with patch.dict(os.environ, {"__CFBundleIdentifier": "", "TERM_PROGRAM": "bad value; rm"}):
            self.assertNotIn("terminal", bridge.agent_event("claude", payload, "running", "working")["agent"])

    def test_codex_provider_and_interrupt(self):
        events, _ = self.run_hook(self.base("Interrupt", turn_id="t1", permission_mode="default"), provider="codex")
        self.assertEqual((events[0]["source"], events[0]["title"], events[0]["state"]), ("codex", "Codex", "waiting"))

    def test_git_context_reads_branch_and_github_origin_without_running_git(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "portfolio"; (repo / ".git").mkdir(parents=True); (repo / "src").mkdir()
            (repo / ".git/HEAD").write_text("ref: refs/heads/feat/stack\n")
            (repo / ".git/config").write_text('[core]\n\tbare = false\n[remote "origin"]\n\turl = git@github.com:argahv/portfolio.git\n')
            self.assertEqual(bridge.git_context(str(repo / "src")), ("feat/stack", "argahv/portfolio"))
            worktree = Path(directory) / "wt"; worktree.mkdir()
            linked = repo / ".git/worktrees/wt"; linked.mkdir(parents=True)
            (linked / "HEAD").write_text("ref: refs/heads/fix\n"); (linked / "commondir").write_text("../..\n")
            (worktree / ".git").write_text("gitdir: " + str(linked) + "\n")
            self.assertEqual(bridge.git_context(str(worktree)), ("fix", "argahv/portfolio"))
            (repo / ".git/config").write_text('[remote "origin"]\n\turl = https://gitlab.com/a/b.git\n')
            self.assertEqual(bridge.git_context(str(repo)), ("feat/stack", None))
            self.assertEqual(bridge.git_context(directory), (None, None))

    def presence(self, root, **changes):
        root.mkdir(parents=True, exist_ok=True)
        config = {"enabled": True, "pid": os.getpid(), "wait": 25}; config.update(changes)
        path = root / "agent-approvals.json"; path.write_text(json.dumps(config)); path.chmod(0o600)
        return path

    def test_presence_file_must_be_private_enabled_and_alive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIsNone(bridge.approvals_config(root))
            path = self.presence(root)
            self.assertEqual(bridge.approvals_config(root), {"wait": 25.0})
            path.chmod(0o644); self.assertIsNone(bridge.approvals_config(root), "group/world-readable presence is ignored")
            self.presence(root, enabled=False); self.assertIsNone(bridge.approvals_config(root))
            dead = subprocess.Popen([sys.executable, "-c", "pass"]); dead.wait()
            self.presence(root, pid=dead.pid); self.assertIsNone(bridge.approvals_config(root), "app not running")
            self.presence(root, wait=900); self.assertEqual(bridge.approvals_config(root), {"wait": 25.0})

    def respond(self, root, events, decision, nonce=None, delay=0.3):
        def answer():
            deadline = time.monotonic() + 5
            while not events and time.monotonic() < deadline: time.sleep(0.02)
            request = events[0]["request"]
            time.sleep(delay)
            responses = root / "responses"; responses.mkdir(mode=0o700, exist_ok=True)
            temporary = responses / ".tmp"
            temporary.write_text(json.dumps({"requestId": request["id"], "nonce": nonce or request["nonce"], "decision": decision}))
            temporary.chmod(0o600)  # mirror the native app's owner-only, atomic response writer
            os.replace(temporary, responses / (request["id"] + ".json"))
        thread = threading.Thread(target=answer); thread.start(); return thread

    def answer(self, root, decision=None, nonce=None, wait=2.0):
        events, out = [], io.StringIO()
        thread = self.respond(root, events, decision, nonce) if decision else None
        payload = self.base("PermissionRequest", tool_name="Bash", tool_input={"command": "npm   publish", "description": "Publish"})
        with patch.object(bridge, "publish", side_effect=lambda event: (bridge.validate(event), events.append(event))), patch.object(sys, "stdout", out):
            self.assertEqual(bridge.answer_permission("claude", payload, "Bash", wait, root), 0)
        if thread: thread.join()
        return events, out.getvalue()

    def test_permission_allowed_from_the_notch(self):
        with tempfile.TemporaryDirectory() as directory:
            events, out = self.answer(Path(directory), "allow")
            request = events[0]["request"]
            self.assertTrue(bridge.is_hex(request["id"]) and bridge.is_hex(request["nonce"]))
            self.assertEqual((request["tool"], request["detail"], events[0]["sensitive"]), ("Bash", "npm publish", True))
            self.assertEqual(json.loads(out), {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
            self.assertEqual((events[-1]["state"], events[-1]["agent"]["state"]), ("running", "executingTool"))
            self.assertEqual(list((Path(directory) / "responses").iterdir()), [], "responses are consumed")

    def test_permission_denied_from_the_notch(self):
        with tempfile.TemporaryDirectory() as directory:
            events, out = self.answer(Path(directory), "deny")
            self.assertEqual(json.loads(out)["hookSpecificOutput"]["decision"]["behavior"], "deny")
            self.assertEqual(events[-1]["agent"]["state"], "working")

    def test_response_requires_private_file_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            response = root / ("a" * 32 + ".json")
            request = {"id": "a" * 32, "nonce": "b" * 32}
            body = json.dumps({"requestId": request["id"], "nonce": request["nonce"], "decision": "allow"})
            response.write_text(body)
            response.chmod(0o644)
            self.assertIsNone(bridge.read_decision(response, request), "world-readable approvals must be ignored")
            self.assertFalse(response.exists(), "invalid responses are consumed")
            target = root / "other.json"
            target.write_text(body)
            response.symlink_to(target)
            self.assertIsNone(bridge.read_decision(response, request), "symlinks must never be followed")
            self.assertTrue(target.exists(), "symlink rejection must not delete the target")
            response.unlink()
            response.write_text(body)
            response.chmod(0o600)
            self.assertEqual(bridge.read_decision(response, request), "allow")
            self.assertFalse(response.exists())

    def test_wrong_nonce_and_timeout_fall_back_to_the_agent_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            events, out = self.answer(Path(directory), "allow", nonce="0" * 32, wait=1.0)
            self.assertEqual(out, "", "no decision: the agent's own prompt takes over")
            self.assertEqual(events[-1]["state"], "needsInput")
            self.assertNotIn("request", events[-1], "the stale request is withdrawn")

    def test_permission_request_without_opt_in_does_not_wait(self):
        started = time.monotonic()
        events, out = self.run_hook(self.base("PermissionRequest", tool_name="Bash", tool_input={"command": "ls"}))
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual((out, len(events)), ("", 1))

    def test_codex_notify_turn_complete(self):
        events = []
        payload = {"type": "agent-turn-complete", "thread-id": "th-1", "turn-id": "t-1", "cwd": "/tmp/portfolio",
                   "input-messages": ["SECRET"], "last-assistant-message": "SECRET"}
        with patch.object(bridge, "publish", side_effect=lambda event: (bridge.validate(event), events.append(event))):
            self.assertEqual(bridge.main(["codex-notify", json.dumps(payload)]), 0)
            self.assertEqual(bridge.main(["codex-notify", json.dumps({"type": "other"})]), 0)
            self.assertEqual(bridge.main(["codex-notify", "not json"]), 0)
        self.assertEqual(len(events), 1)
        self.assertEqual((events[0]["source"], events[0]["activityId"], events[0]["state"]), ("codex", "th-1", "completed"))
        self.assertNotIn("SECRET", json.dumps(events))

    def test_version_two_validation(self):
        now = dt.datetime.now(dt.timezone.utc)
        good = bridge.agent_event("claude", {"session_id": "s", "cwd": "/tmp/x"}, "running", "working")
        bridge.validate(good)
        request = {"id": "a" * 32, "nonce": "b" * 32, "kind": "permission", "tool": "Bash", "expiresAt": bridge.iso_ms(now + dt.timedelta(minutes=1))}
        for changes in ({"state": "completed"}, {"category": "nope"}, {"request": request},
                        {"state": "needsInput", "phase": "waiting", "request": dict(request, id="XYZ")},
                        {"state": "needsInput", "phase": "waiting", "request": dict(request, expiresAt=bridge.iso_ms(now + dt.timedelta(hours=1)))},
                        {"agent": {"provider": "bad provider", "sessionId": "s"}}, {"version": 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                bridge.validate(dict(good, **changes))
        bridge.validate(dict(good, state="needsInput", phase="waiting", request=request))

if __name__ == "__main__": unittest.main()
