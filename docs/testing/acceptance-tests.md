# Acceptance tests

Status key: **Auto** means covered by `swift test` or `python3 -I Tests/test_bridge.py`. **Verified** means
run end to end on the development Mac (2026-10-20) with window-only captures, via the debug-only
`~/Library/Application Support/NotchFlow/debug/*.cmd` channel or real processes. **Manual** means it needs
a person or a real third-party session, with the steps given. Earlier first-pass checks are in
[VERIFICATION.md](../VERIFICATION.md) and [redesign/05-qa-report.md](../redesign/05-qa-report.md).

## Run the automated suites

```bash
swift test
```

```bash
python3 -I Tests/test_bridge.py
```

```bash
python3 -I Scripts/generate_project.py && xcodebuild -project NotchFlow.xcodeproj -scheme NotchFlow -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## Activity engine and stack

| # | Scenario | Expected | Status |
|---|---|---|---|
| A1 | v1 events and stored History decode | Unchanged behaviour | Auto |
| A2 | v2 field validation (state/phase, request rules, lengths) | Invalid events rejected in Swift and Python alike | Auto |
| A3 | Out-of-order and same-instant updates | Older ignored; finished never returns to running | Auto |
| A4 | Burst of hook events within one second | Applied in timestamp order (ms precision, sorted drain) | Auto + Verified |
| A5 | Four concurrent activities at rest | Three tone dots + "4"; urgent leads | Verified |
| A6 | Glance with a backlog | Lead + "+N" chip + stacked layers tinted by state | Verified |
| A7 | Filters All/Agents/CI/Downloads/Done | Rows and surface size follow the filter; empty states are accurate | Verified |
| A8 | Task completes while the stack is open | Stays 6 s, retracts, History pulses, surface shrinks | Verified |
| A9 | Hide a failed CI run | Leaves the stack, stays in Done/History | Verified |
| A10 | Failure older than an hour | Leaves the stack | Auto |
| A11 | Heartbeats / tool updates | Row updates without a new notification | Auto |
| A12 | Opening the workspace with many rows | Sized for the frozen order; nothing clipped; overflow fades and scrolls | Verified |

## Agents

| # | Scenario | Expected | Status |
|---|---|---|---|
| G1 | Every documented hook event maps to the right state | See the mapping table in agent-integrations.md | Auto |
| G2 | Prompts, replies, tool input and transcript paths never published | Absent from events | Auto |
| G3 | Project, branch, GitHub repo (including worktrees) | From .git files, no git process | Auto |
| G4 | PermissionRequest without opt-in | Publishes, returns in under 1 s, prints nothing | Auto + Verified (0.09 s via /bin/sh) |
| G5 | Allow from the notch | Hook prints documented allow JSON; card → Running ‹tool›; response consumed | Auto + Verified |
| G6 | Deny from the notch | Hook prints deny JSON with message | Auto + Verified |
| G7 | No answer | Hook prints nothing after the wait; request withdrawn; "Open ‹host›" becomes primary; a late answer is refused | Auto + Verified |
| G8 | Wrong nonce, dead app pid, world-readable presence file | Ignored / no wait | Auto |
| G9 | Request arrives while the stack is open | Row inserted at the top | Verified |
| G10 | Generated hook configs | Valid JSON; Claude status hooks async, PermissionRequest sync with timeout = wait + 5 | Verified |
| G11 | Live Claude Code session with hooks installed | Cards follow the session; Allow/Deny work | **Manual**: copy Settings › Agents › Claude Code into `~/.claude/settings.json`, turn on answering, run a session that needs Bash permission |
| G12 | Live Codex session | Same with Codex hooks after `/hooks` trust | **Manual** (Codex isn't installed on the development Mac) |

## GitHub Actions

| # | Scenario | Expected | Status |
|---|---|---|---|
| H1 | Status/conclusion mapping, fixture decode, link allowlist, 6-day window | As documented | Auto |
| H2 | Cadence, unauthenticated budget, backoff, Retry-After / reset | As documented | Auto |
| H3 | Public repository without a token | Polls every 180 s idle; status shows it | Verified (cli/cli) |
| H4 | Private repository without a token | "Private repositories need a token"; other repos unaffected | Verified |
| H5 | Conditional request | 304 for an unchanged ETag | Verified against the API |
| H6 | Token save/remove and private polling | Token in Keychain; private runs appear | **Manual**: paste a fine-grained read-only token in Settings › GitHub Actions |

## Clipboard, downloads, meetings, system

| # | Scenario | Expected | Status |
|---|---|---|---|
| C1 | Classifier kinds and best-effort secret detection | As tested | Auto |
| C2 | Copies from a password manager, concealed types, a token | Skipped and counted; never listed | Verified (filters driven through the debug seam) |
| C3 | Real copy/paste cycle on the general pasteboard | Item appears within ~1 s; "Copy" restores it | **Manual** (not exercised, to avoid overwriting the user's clipboard) |
| D1 | Partial → finished download | "Downloading … · size so far" → "Downloaded …" | Verified (scratch folder) |
| D2 | Partial removed | "Download stopped" | Verified (scratch folder; confirmed from the stored record, since the screenshot was interrupted by live use of the app) |
| D3 | Real ~/Downloads access prompt and Safari/Chrome downloads | Prompt once; states as D1 | **Manual** |
| M1 | Join-link extraction | Known HTTPS hosts only | Auto |
| M2 | Real calendar event with a Zoom/Meet link | Quiet at T−10, alert at T−1 with Join, in progress until the end | **Manual** (Calendar not connected on the development Mac) |
| S1 | Sound outputs listed; current default marked | Matches System Settings | Verified (switching not exercised) |
| S2 | System metrics | CPU, memory, thermal, uptime; sampling only while open | Verified |
| B1 | Battery thresholds | 20/10/5 once each while unplugged | Auto (a live drain is **Manual**) |
| N1 | Notification primary action | Review / Join / Show in Finder / Open run / View | Verified (Open run) |

## Context and modes

| # | Scenario | Expected | Status |
|---|---|---|---|
| X1 | Boost per frontmost app; urgency still wins | As tested | Auto |
| X2 | Live activation of an editor-class app | Boost = agent, build, ci, deploy | Verified (Claude desktop frontmost) |
| X3 | Defaults read as Dynamic; changing a setting reads as Custom | As tested | Auto + Verified |

## Performance

| # | Scenario | Expected | Status |
|---|---|---|---|
| P1 | 30 minutes at rest | Idle CPU, wakeups and memory recorded | See [progress.md](../implementation/progress.md) |
