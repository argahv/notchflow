# Maintainer replies

Short, reusable replies for issues, PRs and Discussions. Personalise the first line; never paste these
without reading what the person actually wrote.

## Welcome a new contributor

> Welcome, and thanks for jumping in! A few places to start:
> - [CONTRIBUTING.md](https://github.com/argahv/notchflow/blob/main/CONTRIBUTING.md) covers setup, tests and the PR flow.
> - [Good first issues](https://github.com/argahv/notchflow/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) each list the exact files and acceptance criteria.
> - The [architecture section](https://github.com/argahv/notchflow/blob/main/CONTRIBUTING.md#architecture-in-five-minutes) is a five-minute read.
> - Questions are welcome in [Discussions › Q&A](https://github.com/argahv/notchflow/discussions/categories/q-a).
>
> If you tell me what you'd like to work on (SwiftUI, AppKit, graphics, accessibility, Python hooks, docs), I'll point you at something that fits.

## Help someone choose an issue

> Thanks! Based on what you said, these are good fits:
> - **#__** — _one line on why it fits_
> - **#__** — _one line on why it fits_
>
> Comment "I'll take this" on the one you pick and I'll assign it so nobody else starts on it. If you get stuck, push a draft PR early; it's much easier to help with code in front of us.

## Answer a build question

> Sorry you hit that. Could you share:
> 1. macOS version and Mac model
> 2. `xcodebuild -version`
> 3. the exact command and the first error in the output (not just the last line)
>
> Common fixes: run `python3 Scripts/generate_project.py` after pulling (the Xcode project is generated); make sure Xcode 16+ is selected (`xcode-select -p`); and quit any installed NotchFlow before running a Debug build. Unsigned builds ask for folder access again after each rebuild. Sign with `NOTCHFLOW_SIGN_IDENTITY` to keep permissions ([details](https://github.com/argahv/notchflow/blob/main/CONTRIBUTING.md#clone-build-and-run)).

## Thank a contributor (merged PR)

> Merged, thank you! This will be in the next release, and you'll be credited in the notes. If you'd like another one, #__ is related and builds on what you just did.

## Request changes on a PR

> Thanks for this, it's a good direction. A few things before it can go in:
> - _specific change, with file/line_
> - _specific change, with file/line_
>
> And the checklist items that apply: tests for new NotchCore logic, `python3 Scripts/generate_project.py` if Swift files were added or moved, Reduce Motion via `Motion.reduced`, and a screenshot for UI changes. Happy to pair on any of it. Just ask here.

## Close a duplicate

> Thanks for reporting! This is tracked in #__, so I'm closing this one to keep the discussion in one place. Please add any extra detail (especially your Mac, macOS version and steps) there.

## Decline a feature (kindly)

> Thanks for the thoughtful suggestion. I don't think this fits NotchFlow right now because _reason: e.g. it needs a server / it would open the notch on its own / it's better as a separate tool_. I'm closing it for now, but if you see a way to do it locally and quietly, I'd be glad to reopen.

## Triage incoming feedback

Classify each actionable item before filing:

| Type | Label | Notes |
|---|---|---|
| Bug | `bug` | Needs version, macOS, Mac/display, steps |
| UX problem | `enhancement` + area label | Describe the moment of friction, not the fix |
| Documentation | `documentation` | Link the doc and the confusing line |
| Feature request | `enhancement` | Check it against the principles in CONTRIBUTING |
| Integration request | `integration` | Which tool, which official hook/API it would use |

Search existing issues first. Don't file duplicates; add to the existing issue instead.
