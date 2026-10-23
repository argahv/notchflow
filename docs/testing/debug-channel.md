# Debug channel reference

The Debug channel lets contributors drive app states that are difficult to reach from a test harness. It is compiled only into Debug builds (`#if DEBUG`). In the default configuration it watches `~/Library/Application Support/NotchFlow/debug`; a Debug build also accepts a non-empty `NOTCHFLOW_APP_SUPPORT` override, which is useful for keeping a test run's files and settings in a disposable folder.

Write a UTF-8 command file outside the watched directory or with a temporary extension, then rename it to `*.cmd` only after it is complete. When the directory changes, NotchFlow reads matching files in filename order, attempts to delete each file after reading it, then runs its non-empty lines. Deletion errors are ignored, so a file may remain if removal fails. The directory is created with owner-only permissions. These lines are Debug channel commands, not shell commands: arguments are passed as text, and there is no shell quoting or escaping. The first colon separates the verb from its argument; the `clip` and `drop:text` commands translate the two characters `\n` into a newline.

For example, from the repository root:

```bash
debug="$PWD/build/debug-channel-data/debug"
mkdir -p "$debug"
cat > "$debug/.01.tmp" <<'EOF'
open:tools.notes
note:new
status
EOF
mv "$debug/.01.tmp" "$debug/01.cmd"
```

Run a Debug build with `NOTCHFLOW_APP_SUPPORT` set to that same data folder. See [Contributing](../../CONTRIBUTING.md#debugging-without-special-hardware) for the sandboxed build command. Commands that copy to the clipboard, change preferences, add shelf items, or act on records can have real effects within the selected app data or macOS clipboard; use disposable data and demo content.

## Commands

All names and values below are case-sensitive. Where an argument is described as an identifier, use the corresponding activity, hover item, or shelf item identifier shown by the app/debug status. Some commands use a fallback for unrecognized values; see each command's behavior below.

| Command | Argument forms | Effect | Example `.cmd` line |
| --- | --- | --- | --- |
| `event` | `enter`, `leave`, `expand`, `dismiss`, `pin`, `approach`, `dragApproach`, `retreat`, `beginEditing`, `endEditing` | Sends the named interaction event to the app. | `event:enter` |
| `open` | `activity[.<activity-id>]`, `music`, `shelf`, `tools[.<tool>]`, `history`, `command`; tool: `notes`, `todos`, `clipboard`, `calendar`, `timer`, `apps`, `sound`, `system`, `mirror`, `shortcuts` | Opens the route; a tool or activity detail may be selected where shown. | `open:tools.notes` |
| `back` | no argument | Navigates back. | `back` |
| `close` | no argument | Closes the NotchFlow window. | `close` |
| `hover` | `enter` or any other value | Starts hover, or ends pointer presence for any value other than `enter`. | `hover:enter` |
| `note` | `new` or any other value | Opens a new note, or closes the note for any value other than `new`. | `note:new` |
| `detail` | `<activity-id>` | Toggles detail for that activity while the activity route is open. | `detail:activity-123` |
| `notification` | `view`, `primary`, or any other value | Opens notification details; runs the lead notification's primary action; or dismisses it. | `notification:view` |
| `query` | `<text>` | Sets the command palette query. | `query:clipboard` |
| `timer` | `<integer-minutes>` | Starts a timer for that many minutes; a non-integer cancels the timer. | `timer:1` |
| `media` | `on`, `off` | Enables media observation for `on`; any other value disables it. | `media:on` |
| `reduceMotion` | `on`, `off` | Sets NotchFlow's Reduce Motion value for `on`; any other value sets it off. | `reduceMotion:on` |
| `quiet` | `on`, `off` | Turns Quiet mode on for `on`; any other value turns it off. | `quiet:on` |
| `filter` | `all`, `agents`, `pipelines`, `downloads`, `done` | Changes the activity stack filter. | `filter:all` |
| `hide` | `<activity-id>` | Hides the matching activity from the stack. | `hide:activity-123` |
| `pinRecord` | `<activity-id>` | Toggles the matching activity's pinned state. | `pinRecord:activity-123` |
| `clip` | `<text>`, `1password:<text>`, `safari:<text>`, `concealed:<text>` | Sends test text through the clipboard filters as Xcode, 1Password, Safari, or a concealed copy. Only plain `clip:<text>` turns literal `\n` into a newline; the `1password:`, `safari:`, and `concealed:` forms pass it through unchanged. | `clip:Demo text` |
| `suggest` | `on`, `off`, `run[:<index>]`, `why`, `dismiss`, `undo`, `reset`, `sensitivity:<fewer\|balanced\|more>` | Enables suggestions and clipboard suggestions, turns clipboard suggestions off, runs an offered action (default index `0`), toggles its explanation, dismisses/undoes it, resets learning, or changes sensitivity. | `suggest:on` |
| `rescue` | `<activity-id>`, `copy` | Prepares a handoff brief for the activity, or copies the brief to the real macOS clipboard. | `rescue:activity-123` |
| `chain` | `web-ready-images`, `compress-and-zip`, `document-bundle`, `pages-as-images` | Runs that action chain on compatible items already on the shelf. | `chain:web-ready-images` |
| `next` | `<zero-based-index>` | Runs the indexed next action offered after an action creates files. | `next:0` |
| `pointer` | `scripted`, `real` | Ignores real pointer input for scripted QA, or resumes using the real pointer. | `pointer:scripted` |
| `focus` | `<seconds>`, `stop`, `guard:on`, `guard:off` | Starts a timed focus session, ends the timer, or enables/disables Flow Guardian. | `focus:60` |
| `privacy` | `on`, `off` | Hides private details for `on`; any other value turns privacy mode off. | `privacy:on` |
| `front` | `real`, `<bundle-id>[\|<app-name>]` | Resumes the real frontmost-app observer, or scripts a frontmost app through the normal context gate. | `front:com.apple.finder` |
| `mode` | `pin:<general\|developer\|meeting\|media\|creative\|study>`, `auto`, `follow:on`, `follow:off`, `settle:<seconds>` | Pins or clears the work mode, enables/disables mode inference, or sets the debug settle delay. | `mode:pin:developer` |
| `nowplaying` | `<title>[\|<artist>]`, `off` | Scripts a Now Playing item, or clears it. | `nowplaying:Night Drive` |
| `hoverOpen` | `primary`, `ambient`, `count` | Opens the primary or ambient hover item, or the activity stack from the count chip. | `hoverOpen:primary` |
| `clearActivities` | no argument | Clears activity history and reflows the stack. | `clearActivities` |
| `portal` | `near[:<kind>[:<count>]]`, `close[:<kind>[:<count>]]`, `enter[:<kind>[:<count>]]`, `exit`, `away`; kind: `file`, `folder`, `image`, `pdf`, `audio`, `video`, `link`, `text`, `mixed` | Scripts drag proximity or entry/exit; a supplied kind defaults to one item (an unknown kind becomes `file`), `enter` without cargo reuses current cargo, and `away` resets proximity. | `portal:near:file:1` |
| `drop` | `file:<path>[\|<path>...]`, `text:<text>`, `link:<url>` | Sends file, text, or link content through the shelf drop path; literal `\n` in text becomes a newline. | `drop:text:Demo text` |
| `pasteboard` | `<pasteboard-name>` | Reads the named macOS pasteboard through the normal drop receiver. | `pasteboard:com.example.NotchFlowTest` |
| `sound` | `connected:<name>`, `switched:<name>` | `connected` scripts an output connection; `switched` scripts an output switch. Any other prefix follows the switched path. | `sound:connected:QA headphones` |
| `timeline` | `open`, `move[:<steps>]`, `now` | Opens the timeline, moves its cursor (positive steps go earlier; default `1`), or returns it to the present. | `timeline:open` |
| `split` | `next:primary\|secondary`, `prev:primary\|secondary`, `pin:<hover-id>` | Cycles a split hover choice or pins the named hover item. | `split:next:primary` |
| `screenshots` | `watch`, `stop` | Starts or stops the screenshot watcher without changing its saved setting. Any value other than `watch` stops it. | `screenshots:stop` |
| `capture` | `text`, `annotate`, `dismiss`, `<absolute-path>` | Reads capture text, opens annotation, dismisses the capture, or delivers an absolute path as a detected screenshot. | `capture:text` |
| `annotate` | `undo`, `redo`, `clear`, `save`, `<tool>:<x1>,<y1>,<x2>,<y2>[:<text>]`; tool: `arrow`, `rectangle`, `highlight`, `text`, `blur`, `redact` | Edits the current capture; coordinates are image fractions from the top-left, clamped to `0...1`. | `annotate:arrow:0.1,0.1,0.8,0.8` |
| `actions` | `cancel`, `undo`, `pdfs[:<action>]`, `<item-name-prefix>[:<action>]`; action: `copy`, `quickLook`, `open`, `reveal`, `createNote`, `annotate`, `extractText`, `removeBackground`, `convertPNG`, `convertJPEG`, `convertHEIC`, `resizeHalf`, `compress`, `pdfText`, `exportPages`, `splitPages`, `mergePDFs`, `cleanWhitespace`, `uppercase`, `lowercase`, `titleCase`, `wordCount`, `detectLanguage`, `linkPreview`, `qrCode`, `mediaInfo`, `extractFrame`, `convertM4A`, `compressVideo`, `createArchive` | Cancels/undoes an action, or opens Actions for all shelf PDFs or the first item whose name starts with the prefix, optionally starting the named action. | `actions:Demo:wordCount` |
| `shelf` | `clear`, `undo` | Clears the shelf or undoes the last shelf removal. | `shelf:undo` |
| `snapshot` | `<letters-digits-hyphens>[:light]` | Saves a window snapshot under `debug/<name>.png`, using the light appearance only when requested. | `snapshot:qa-example:light` |
| `status` | no argument | Writes a text status report to `debug/status.txt`. | `status` |
| `dumpHooks` | no argument | Writes generated Claude, Codex, and Codex-notify hook examples under the debug directory. | `dumpHooks` |
| `allow` | `<activity-id>` | Allows the matching pending permission request. | `allow:activity-123` |
| `deny` | `<activity-id>` | Denies the matching pending permission request. | `deny:activity-123` |

## Worked acceptance example: C2 clipboard filtering

Acceptance scenario [C2](acceptance-tests.md#clipboard-downloads-meetings-system) checks that password-manager copies, concealed copies, and text that looks like a token are skipped and counted without being listed. Use a Debug build with a throwaway support directory as described in [Contributing](../../CONTRIBUTING.md#debugging-without-special-hardware). With that build running, enable clipboard suggestions and allow the observer to reconfigure:

```bash
debug="$PWD/build/debug-channel-data/debug"
mkdir -p "$debug"
cat > "$debug/.01-c2-setup.tmp" <<'EOF'
suggest:on
suggest:reset
privacy:off
quiet:off
EOF
mv "$debug/.01-c2-setup.tmp" "$debug/01-c2-setup.cmd"
sleep 1
```

Then send three synthetic copies and request a status report:

```bash
cat > "$debug/.02-c2-copies.tmp" <<'EOF'
clip:1password:https://bank.example/login
clip:concealed:private-demo-copy
clip:ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234
status
EOF
mv "$debug/.02-c2-copies.tmp" "$debug/02-c2-copies.cmd"
```

The Debug channel attempts to remove each `.cmd` file after reading it; removal errors are ignored. Check `debug/status.txt`: the clipboard line should report `skipped 3`, with no listed items or suggestion containing the sample copies. This example uses only synthetic text and does not read or write the real clipboard. The checked-in [suggestion acceptance runner](../../Scripts/qa_suggestions.py) also exercises the password-manager and token filters in its `coordination` scenario.

The command implementation is in [`DebugChannel.swift`](../../Sources/NotchFlow/Window/DebugChannel.swift); this reference should track its accepted forms.
