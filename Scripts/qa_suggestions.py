"""Acceptance checks for Sixth Sense suggestions, run against a Debug build through its Debug channel.

Debug builds only, with their own data folder so nothing reaches your real shelf, inbox or history:

    xcodebuild -project NotchFlow.xcodeproj -scheme NotchFlow -configuration Debug -derivedDataPath build/Sandbox \
      PRODUCT_BUNDLE_IDENTIFIER=com.argahv.notchflow.dev CODE_SIGNING_ALLOWED=NO build
    NOTCHFLOW_APP_SUPPORT="$PWD/build/sandbox-data" build/Sandbox/Build/Products/Debug/NotchFlow.app/Contents/MacOS/NotchFlow &
    python3 -I Scripts/qa_suggestions.py "$PWD/build/sandbox-data" [all|basic|shelf|coordination|regression]

Copies are fed to ClipboardService.consider (the filters a real copy passes), so the real clipboard is never
read or written. Activity events are written to the sandbox inbox only. Snapshots land in <data>/debug/*.png.
"""
import json, os, sys, time, datetime, uuid

ROOT = sys.argv[1]
DEBUG = os.path.join(ROOT, "debug")
INBOX = os.path.join(ROOT, "inbox")
seq = [0]


def send(*lines, wait=0.6):
    seq[0] += 1
    tmp = os.path.join(DEBUG, f".{seq[0]:04d}.tmp")
    with open(tmp, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.rename(tmp, os.path.join(DEBUG, f"{int(time.time()*1000)}-{seq[0]:04d}.cmd"))
    time.sleep(wait)


def status():
    path = os.path.join(DEBUG, "status.txt")
    if os.path.exists(path):
        os.remove(path)
    send("status", wait=0.5)
    with open(path) as handle:
        return dict(line.split(": ", 1) for line in handle.read().splitlines() if ": " in line)


def snap(name, light=False):
    send(f"snapshot:{name}" + (":light" if light else ""), wait=1.0)
    return os.path.join(DEBUG, f"{name}.png")


def event(activity, state, title, category="build", summary=None):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    phase = {"failed": "failed", "completed": "completed", "running": "progress", "needsInput": "waiting"}[state]
    body = {"version": 2, "source": "qa", "activityId": activity, "phase": phase, "state": state, "title": title,
            "category": category, "timestamp": now}
    if summary:
        body["summary"] = summary
    path = os.path.join(INBOX, f"qa-{uuid.uuid4().hex}.json")
    with open(path, "w") as handle:
        json.dump(body, handle)
    os.chmod(path, 0o600)


results = []


def check(label, condition, detail=""):
    results.append((label, bool(condition), detail))
    print(("PASS " if condition else "FAIL ") + label + (f"  [{detail}]" if detail else ""))


def line(key):
    return status().get(key, "")


scenario = sys.argv[2] if len(sys.argv) > 2 else "all"
os.makedirs(DEBUG, exist_ok=True)

if scenario in ("all", "basic"):
    send("suggest:on", "suggest:reset", "privacy:off", "quiet:off", wait=1.0)
    s = status()
    check("copy suggestions start the clipboard source", "clipboard=on" in s.get("context sources", ""), s.get("context sources"))

    send("clip:https://github.com/argahv/notchflow?utm_source=newsletter&ref_src=twsrc", wait=1.2)
    s = status()
    check("a tracked link copied in Xcode is suggested", "clipboard.link" in s.get("suggestion", ""), s.get("suggestion"))
    check("its first action is Copy Clean Link", "Copy Clean Link,Open,Keep on Shelf" in s.get("suggestion", ""), s.get("suggestion"))
    check("the glance is the suggestion", "suggestion(" in s.get("capture", ""), s.get("capture"))
    snap("qa-1-link")
    send("suggest:why", wait=0.8)
    check("Why opens", "why true" in line("suggestion"))
    snap("qa-2-why")
    send("suggest:why", "suggest:dismiss", wait=1.0)
    s = status()
    check("dismiss closes the glance", s.get("suggestion", "").startswith("-"), s.get("suggestion"))
    check("dismissal is learned for the rule", "clipboard.link +0 -1" in s.get("learning", ""), s.get("learning"))

    send("clip:https://example.org/other", wait=1.2)
    s = status()
    check("after a dismissal the same rule cools down", "cooling down" in s.get("inspector", ""), s.get("inspector"))

    send("clip:#0A84FF", wait=1.2)
    s = status()
    check("a color is suggested with RGB and HSL", "Copy as RGB,Copy as HSL" in s.get("suggestion", ""), s.get("suggestion"))
    snap("qa-3-color")
    send("suggest:sensitivity:more", wait=0.4)
    send('clip:{"name":"notchflow","tags":["notch","mac"],"stars":42}', wait=1.2)
    s = status()
    check("a newer copy replaces the suggestion in place", "clipboard.json" in s.get("suggestion", ""), s.get("suggestion"))
    snap("qa-4-json")
    send("suggest:dismiss", "suggest:sensitivity:balanced", wait=1.0)

if scenario in ("all", "shelf"):
    long_text = " ".join(["Sixth Sense keeps every decision on this Mac and explains itself."] * 6)
    send("suggest:on", "suggest:reset", "privacy:off", "suggest:sensitivity:more", wait=1.0)
    send(f"clip:{long_text}", wait=1.2)
    s = status()
    check("a long passage is suggested under More", "clipboard.prose" in s.get("suggestion", ""), s.get("suggestion"))
    before = s.get("portal", "")
    send("suggest:run:0", wait=1.2)
    s = status()
    check("Keep on Shelf reports its result with Undo", "Kept on the shelf" in s.get("suggestion", "") and "undo=true" in s.get("suggestion", ""), s.get("suggestion"))
    check("the shelf gained an item", "shelf: 1" in s.get("portal", ""), f"{before} -> {s.get('portal')}")
    snap("qa-5-kept")
    send("suggest:undo", wait=1.0)
    s = status()
    check("Undo removes it from the shelf", "shelf: 0" in s.get("portal", ""), s.get("portal"))
    check("accepting is learned", "clipboard.prose +1" in s.get("learning", ""), s.get("learning"))
    send("suggest:dismiss", "suggest:sensitivity:balanced", wait=1.0)

if scenario in ("all", "coordination"):
    send("suggest:on", "suggest:reset", "privacy:off", "quiet:off", wait=1.0)
    # A suggestion never takes the surface from a drag; it waits and appears once the drag is gone.
    send("portal:near:file:1", wait=0.6)
    send("clip:#112233", wait=1.0)
    s = status()
    check("during a drag the suggestion waits", "pending clipboard.color" in s.get("suggestion", "") and s.get("suggestion", "").startswith("-"), s.get("suggestion"))
    send("portal:away", wait=1.6)
    s = status()
    check("after the drag it appears", "clipboard.color" in s.get("suggestion", "").split(" · pending")[0], s.get("suggestion"))
    # Passive news waits behind a suggestion; a failure takes the surface.
    event("qa-build-ok-" + uuid.uuid4().hex[:6], "completed", "Build finished")
    time.sleep(1.2)
    s = status()
    check("a finished build waits behind the suggestion", "clipboard.color" in s.get("suggestion", "").split(" · pending")[0], s.get("suggestion"))
    event("qa-ci-" + uuid.uuid4().hex[:6], "failed", "CI failed on main", category="ci", summary="3 tests failed")
    time.sleep(1.4)
    s = status()
    check("a failure takes the surface from the suggestion", "notification(" in s.get("capture", ""), s.get("capture"))
    check("the replaced suggestion is superseded, not dismissed", "clipboard.color" not in s.get("learning", "") or "-0" in s.get("learning", ""), s.get("learning"))
    snap("qa-6-failure")
    send("notification:dismiss", wait=1.0)
    # Private details hidden: nothing from the clipboard is suggested.
    send("privacy:on", wait=0.6)
    send("clip:#445566", wait=1.0)
    s = status()
    check("with details hidden nothing is suggested", s.get("suggestion", "").startswith("-") and "pending -" in s.get("suggestion", ""), s.get("suggestion"))
    check("the inspector says why", "Private details are hidden" in s.get("inspector", ""), s.get("inspector"))
    check("the inspector never shows copied content", "445566" not in s.get("inspector", "") and "github.com" not in s.get("inspector", ""), s.get("inspector"))
    send("privacy:off", wait=0.4)
    # Excluded and secret copies never reach the engine.
    send("clip:1password:https://bank.example/login", wait=0.8)
    send("clip:ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234", wait=0.8)
    s = status()
    check("password-manager and secret-looking copies are skipped", "skipped 2" in s.get("clipboard", ""), s.get("clipboard"))
    send("suggest:off", wait=0.8)
    s = status()
    check("turning suggestions off stops the clipboard source", "clipboard=off" in s.get("context sources", ""), s.get("context sources"))

if scenario in ("all", "regression"):
    # Notch Actions still run, now through ActionGuard.
    send("drop:text:Guarded actions still count these five words", wait=1.2)
    send("actions:Guarded:wordCount", wait=1.5)
    s = status()
    check("Notch Actions still run through the guard", "completed(" in s.get("action", "") and "wordCount" in s.get("action", ""), s.get("action"))
    send("close", "shelf:clear", wait=0.8)

print()
print(f"{sum(ok for _, ok, _ in results)}/{len(results)} checks passed")
