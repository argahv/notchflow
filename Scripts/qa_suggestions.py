"""Acceptance checks for Sixth Sense suggestions, run against a Debug build through its Debug channel.

Debug builds only, with their own data folder so nothing reaches your real shelf, inbox or history:

    xcodebuild -project NotchFlow.xcodeproj -scheme NotchFlow -configuration Debug -derivedDataPath build/Sandbox \
      PRODUCT_BUNDLE_IDENTIFIER=com.argahv.notchflow.dev CODE_SIGNING_ALLOWED=NO build
    NOTCHFLOW_APP_SUPPORT="$PWD/build/sandbox-data" build/Sandbox/Build/Products/Debug/NotchFlow.app/Contents/MacOS/NotchFlow &
    python3 -I Scripts/qa_suggestions.py "$PWD/build/sandbox-data" [all|basic|shelf|coordination|regression|surface|modes|downloads|focus|chains|rescue]

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


def event(activity, state, title, category="build", summary=None, action_url=None, extra=None):
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    phase = {"failed": "failed", "completed": "completed", "running": "progress", "needsInput": "waiting"}[state]
    body = {"version": 2, "source": "qa", "activityId": activity, "phase": phase, "state": state, "title": title,
            "category": category, "timestamp": now}
    if summary:
        body["summary"] = summary
    if action_url:
        body["actionURL"] = action_url
    body.update(extra or {})
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
# The real pointer is ignored for the run, so moving the mouse while it runs can't change a result.
send("pointer:scripted", wait=0.3)

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

if scenario in ("all", "surface"):
    # One coordinator for everything that waits: screenshots, sound changes, suggestions and alerts.
    import shutil
    shot = os.path.join(ROOT, "qa-shot.png")
    shutil.copyfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "media", "resting.png"), shot)
    send("suggest:on", "suggest:reset", "privacy:off", "quiet:off", "close", wait=1.0)
    send("clip:#2E8B57", wait=1.0)
    send(f"capture:{shot}", wait=1.2)
    s = status()
    check("a screenshot waits behind a suggestion", "suggestion(" in s.get("capture", "") and "capture/Suggestion" in s.get("waiting", ""),
          f"{s.get('capture')} | {s.get('waiting')}")
    send("suggest:dismiss", wait=1.6)
    s = status()
    check("then it takes the surface", "glance: capture(" in s.get("capture", ""), s.get("capture"))
    send("sound:connected:QA Headphones", wait=1.0)
    s = status()
    check("a sound change waits behind the screenshot", "sound/Passive news" in s.get("waiting", ""), s.get("waiting"))
    event("qa-fail-" + uuid.uuid4().hex[:6], "failed", "Deploy failed", category="deploy")
    time.sleep(1.4)
    s = status()
    check("a failure takes the surface from the screenshot", "notification(" in s.get("capture", ""), s.get("capture"))
    check("and the screenshot waits to come back", "capture/Suggestion" in s.get("waiting", ""), s.get("waiting"))
    send("notification:dismiss", wait=1.6)
    s = status()
    check("after the failure the screenshot returns before the stale sound change", "glance: capture(" in s.get("capture", ""),
          f"{s.get('capture')} | {s.get('waiting')}")
    send("capture:dismiss", wait=1.5)
    # Two alerts, Escape while the first shows: the second must still be shown (no alert stuck as current unseen).
    first, second = "qa-a-" + uuid.uuid4().hex[:6], "qa-b-" + uuid.uuid4().hex[:6]
    event(first, "failed", "First failure", category="ci")
    time.sleep(1.2)
    event(second, "failed", "Second failure", category="ci")
    time.sleep(1.0)
    send("event:dismiss", wait=1.8)
    s = status()
    check("after Escape the queued alert is shown", f'notification("qa:{second}")' in s.get("capture", ""), s.get("capture"))
    send("notification:dismiss", "suggest:off", wait=0.8)
    os.remove(shot)

if scenario in ("all", "modes"):
    # Intent Switch: an inferred work mode that settles, a pin that wins, a call that switches at once.
    send("clearActivities", "mode:auto", "mode:follow:on", "mode:settle:2", "suggest:on", "suggest:reset", "privacy:off", "quiet:off", wait=1.0)
    # Start from General whatever ran before: Finder in front, held past the settle time.
    send("front:com.apple.finder|Finder", wait=2.6)
    send("front:com.apple.finder|Finder", wait=0.4)
    send("front:com.apple.dt.Xcode|Xcode", wait=0.6)
    s = status()
    check("a new app in front is only pending at first", s.get("work mode", "").startswith("general") and "pending developer" in s.get("work mode", ""),
          s.get("work mode"))
    time.sleep(2.2)
    s = status()
    check("after it holds, the mode is Developer with its reason", s.get("work mode", "").startswith("developer · Xcode is in front"), s.get("work mode"))
    check("Developer offers Activity, Clipboard and Shelf", "shortcuts activity,clipboard,shelf · line true" in s.get("work mode", ""), s.get("work mode"))
    check("and ranks agents, builds and CI first", "agent,build,ci,deploy" in s.get("context", ""), s.get("context"))
    send("front:com.figma.Desktop|Figma", wait=0.6)
    send("front:com.apple.dt.Xcode|Xcode", wait=2.6)
    s = status()
    check("a glance at another app doesn't flip it", s.get("work mode", "").startswith("developer") and "pending -" in s.get("work mode", ""),
          s.get("work mode"))
    send("hover:enter", wait=0.9)
    snap("qa-7-mode-quick")
    send("hover:leave", wait=0.8)
    send("mode:pin:creative", wait=0.8)
    s = status()
    check("a pinned mode wins and says so", s.get("work mode", "").startswith("creative · Pinned"), s.get("work mode"))
    send("clip:#0A84FF", wait=1.2)
    s = status()
    check("Creative lifts a color's score", "clipboard.color" in s.get("suggestion", "") and "score 0.83" in s.get("suggestion", ""), s.get("suggestion"))
    send("suggest:dismiss", "suggest:reset", "mode:auto", wait=1.0)
    call = "qa-call-" + uuid.uuid4().hex[:6]
    event(call, "running", "QA Standup", category="meeting")
    time.sleep(1.2)
    s = status()
    check("a call switches to Meeting at once", s.get("work mode", "").startswith("meeting · “QA Standup” is on"), s.get("work mode"))
    check("Meeting offers Calendar, Notes and Sound", "shortcuts calendar,notes,sound" in s.get("work mode", ""), s.get("work mode"))
    check("and ranks the call first", "meeting" in s.get("context", ""), s.get("context"))
    send("clip:https://example.com/agenda", wait=1.2)
    s = status()
    check("a link copied during the call is held", s.get("suggestion", "").startswith("-") and "clipboard.link" in s.get("inspector", ""),
          f"{s.get('suggestion')} | {s.get('inspector')}")
    event(call, "completed", "QA Standup", category="meeting")
    time.sleep(3.0)
    s = status()
    check("when the call ends the mode settles back", s.get("work mode", "").startswith("developer"), s.get("work mode"))
    send("mode:follow:off", wait=0.8)
    s = status()
    check("with following off it's General", s.get("work mode", "").startswith("general · Following what you do is off"), s.get("work mode"))
    send("mode:follow:on", "mode:settle:15", "suggest:off", "notification:dismiss", "front:real", wait=0.6)

if scenario in ("all", "downloads"):
    # A finished download a suggestion fits shows that suggestion instead of its plain notice; others keep the notice.
    import pathlib, shutil, zipfile
    tag = uuid.uuid4().hex[:6]
    archive, image, text = (os.path.join(ROOT, f"qa-{name}-{tag}.{ext}") for name, ext in (("assets", "zip"), ("photo", "png"), ("notes", "txt")))
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("readme.txt", "hello")
    shutil.copyfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "media", "resting.png"), image)
    with open(text, "w") as handle:
        handle.write("plain notes")

    def finished(path):
        event("dl-" + uuid.uuid4().hex[:6], "completed", "Downloaded " + os.path.basename(path), category="download",
              action_url=pathlib.Path(path).as_uri())
        time.sleep(1.3)

    send("suggest:on", "suggest:reset", "privacy:off", "quiet:off", "focus:stop", "close", wait=1.0)
    finished(archive)
    s = status()
    check("a finished archive offers Extract and Show in Finder", "download.archive · Archive downloaded · Extract,Show in Finder" in s.get("suggestion", ""),
          s.get("suggestion"))
    check("in place of its plain notice", "glance: suggestion(" in s.get("capture", ""), s.get("capture"))
    snap("qa-8-download")
    check("the inspector never names the file", "Downloaded an archive" in s.get("inspector", "") and "assets-" not in s.get("inspector", ""),
          s.get("inspector"))
    send("suggest:dismiss", wait=1.0)
    finished(image)
    s = status()
    check("a finished image offers its actions", "download.image · Image downloaded · Actions…,Show in Finder" in s.get("suggestion", ""),
          f"{s.get('suggestion')} | {s.get('capture')} | {s.get('inspector')} | {s.get('work mode')}")
    send("suggest:run:0", wait=1.5)
    s = status()
    check("Actions opens Notch Actions on the file, kept by reference", "actions" in s.get("route", "") and "image qa-photo-" in s.get("action context", ""),
          f"{s.get('route')} | {s.get('action context')}")
    send("close", "shelf:clear", wait=1.0)
    finished(text)
    s = status()
    check("a file no rule fits keeps its plain notice", 'glance: notification("qa:dl-' in s.get("capture", ""), s.get("capture"))
    send("notification:dismiss", "suggest:off", wait=0.8)
    for path in (archive, image, text):
        os.remove(path)

if scenario in ("all", "focus"):
    # Flow Guardian: during a focus session only work that needs you comes through; the end says what waited.
    tag = uuid.uuid4().hex[:6]
    send("suggest:on", "suggest:reset", "privacy:off", "quiet:off", "focus:guard:on", "close", wait=1.0)
    started = time.time()
    send("focus:10", wait=0.8)
    s = status()
    check("a focus session holds updates", s.get("focus", "").startswith("holding"), s.get("focus"))
    event("fb-" + tag, "completed", "Build finished", category="build")
    time.sleep(1.2)
    s = status()
    check("a finished build waits without a glance", "notification(" not in s.get("capture", "") and "waiting 1" in s.get("focus", ""),
          f"{s.get('capture')} | {s.get('focus')}")
    event("ff-" + tag, "failed", "Deploy failed", category="deploy")
    time.sleep(1.2)
    s = status()
    check("a failure still comes through", f'notification("qa:ff-{tag}")' in s.get("capture", ""), s.get("capture"))
    send("notification:dismiss", wait=0.8)
    send("clip:#123456", wait=1.0)
    s = status()
    check("a copy suggestion waits too", "A focus session is running" in s.get("inspector", "") and "waiting 2" in s.get("focus", ""),
          f"{s.get('inspector')} | {s.get('focus')}")
    time.sleep(max(0.5, 11.5 - (time.time() - started)))
    s = status()
    check("the end says what waited", s.get("focus", "").startswith("off") and "1 update and 1 suggestion waited waited=2" in s.get("focus", ""),
          s.get("focus"))
    shown = "notification(\"timer:" in s.get("capture", "") or "waited" in s.get("celebration", "")
    check("as the session's own end-of-session glance (unless you were typing)", shown, f"{s.get('capture')} | {s.get('celebration')}")
    snap("qa-9-focus-end")
    send("notification:dismiss", "suggest:off", wait=0.6)

if scenario in ("all", "chains"):
    # Action Chains, the Next Action, QR Bridge and one search, through the real executors and the real shelf.
    import glob, hashlib, shutil, zipfile
    media = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "media")
    tag = uuid.uuid4().hex[:6]
    originals = [os.path.join(ROOT, f"qa-chain-{tag}-{name}") for name in ("one.png", "two.png")]
    for source, target in zip(("resting.png", "portal.png"), originals):
        shutil.copyfile(os.path.join(media, source), target)
    digest = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
    before = [digest(path) for path in originals]

    def until(predicate, seconds=20):
        deadline = time.time() + seconds
        while time.time() < deadline:
            current = status()
            if predicate(current):
                return current
            time.sleep(0.5)
        return status()

    send("close", "shelf:clear", "suggest:on", "suggest:reset", "privacy:off", "focus:stop", wait=1.0)
    send("drop:file:" + "|".join(originals), wait=1.5)
    send("chain:web-ready-images", wait=0.5)
    s = until(lambda s: s.get("chain", "").startswith("-") and "completed(" in s.get("action", ""))
    check("Web-Ready Images runs both steps and hands its results to the shelf", "completed(NotchFlow.ContentAction.compress" in s.get("action", "")
          and "created: 2" in s.get("action", ""), s.get("action"))
    shelf_root = os.path.join(ROOT, "Shelf")
    # The resized copies the first step made ("one (50%).png") are removed; the final files keep the name.
    halves = glob.glob(os.path.join(ROOT, "**", "*(50%).png"), recursive=True)
    check("what it made in between is gone", not halves, ", ".join(os.path.basename(p) for p in halves))
    check("the originals are byte for byte unchanged", [digest(path) for path in originals] == before)
    check("the next step for two new images is an archive", s.get("chain", "").endswith("next createArchive,copy"), s.get("chain"))
    history = json.load(open(os.path.join(ROOT, "activities.json")))
    chains = [r for r in history.get("records", []) if r.get("event", {}).get("source") == "chain"]
    check("the chain is a task in the stack and History", any(r["event"].get("state") == "completed" and "originals unchanged" in (r["event"].get("summary") or "")
                                                          for r in chains), str([r["event"].get("summary") for r in chains][-1:]))
    send("next:0", wait=0.5)
    s = until(lambda s: "completed(NotchFlow.ContentAction.createArchive" in s.get("action", ""))
    archives = sorted(glob.glob(os.path.join(ROOT, "**", "Archive*.zip"), recursive=True), key=os.path.getmtime)
    entries = zipfile.ZipFile(archives[-1]).namelist() if archives else []
    check("the next step makes one ZIP of both results", len([e for e in entries if e.endswith((".jpg", ".jpeg"))]) == 2, f"{s.get('action')} | {entries}")
    # Closing the workspace lets the chain's finished notice show; a suggestion waits behind it, so clear it first.
    send("close", "shelf:clear", wait=1.2)
    send("notification:dismiss", wait=1.0)
    send("clip:https://example.com/qa-" + tag, wait=1.3)
    s = status()
    check("a copied link offers a QR code", "QR Code" in s.get("suggestion", ""), s.get("suggestion"))
    parts = s.get("suggestion", "").split(" · ")
    actions = parts[2].split(",") if len(parts) > 2 else []
    send(f"suggest:run:{actions.index('QR Code') if 'QR Code' in actions else 99}", wait=0.5)
    s = until(lambda s: "completed(NotchFlow.ContentAction.qrCode" in s.get("action", ""))
    codes = glob.glob(os.path.join(ROOT, "**", "QR example.com*.png"), recursive=True)
    check("QR Code makes a PNG on the shelf, and Copy comes next", codes and s.get("chain", "").endswith("next copy"), f"{s.get('action')} | {s.get('chain')}")
    send("open:command", "query:QR example", wait=0.8)
    s = status()
    check("one search finds what's on the shelf", "shelf" in s.get("search", ""), s.get("search"))
    send("query:", "close", "shelf:clear", "suggest:off", wait=0.8)
    for path in originals:
        os.remove(path)

if scenario in ("all", "rescue"):
    # Agent Rescue: a failed run offers a brief to review and copy; nothing is sent, and the clipboard isn't touched here.
    tag = uuid.uuid4().hex[:6]
    send("close", "suggest:off", "focus:stop", wait=1.0)
    event("ci-" + tag, "failed", "Unit tests", category="ci", summary="3 tests failed in CheckoutTests",
          action_url="https://github.com/argahv/notchflow/actions/runs/42", extra={"project": "argahv/notchflow", "branch": "main"})
    time.sleep(1.4)
    s = status()
    check("a failed CI run's glance offers Handoff", f'notification("qa:ci-{tag}")' in s.get("capture", "") and "offered true" in s.get("handoff", ""),
          f"{s.get('capture')} | {s.get('handoff')}")
    snap("qa-10-failure-handoff")
    send(f"rescue:qa:ci-{tag}", wait=1.2)
    s = status()
    check("Handoff opens the brief to review, in the workspace", f'handoff("qa:ci-{tag}")' in s.get("route", "") and "expanded" in s.get("route", ""),
          s.get("route"))
    check("the brief names the failure", "## CI run failed: Unit tests" in s.get("handoff", "") and "copied false" in s.get("handoff", ""), s.get("handoff"))
    snap("qa-11-handoff")
    send("close", wait=1.0)
    send("notification:dismiss", wait=0.6)
    event("dl-" + tag, "failed", "Download failed", category="download")
    time.sleep(1.4)
    s = status()
    check("a failed download isn't offered a handoff", "offered false" in s.get("handoff", ""), s.get("handoff"))
    send("notification:dismiss", wait=0.6)

send("pointer:real", "front:real", wait=0.3)
print()
print(f"{sum(ok for _, ok, _ in results)}/{len(results)} checks passed")
