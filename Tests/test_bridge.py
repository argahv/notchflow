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

if __name__ == "__main__": unittest.main()
