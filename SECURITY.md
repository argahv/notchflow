# Security policy

NotchFlow reads agent hook events, answers agent permission requests, watches the clipboard (opt-in) and
handles files you drop on it. Security reports are taken seriously and handled privately.

## Supported versions

NotchFlow is a developer preview. Only the latest release and `main` get security fixes.

| Version | Supported |
|---|---|
| Latest release (see [Releases](https://github.com/argahv/notchflow/releases/latest)) | Yes |
| `main` | Yes |
| Older releases | No. Please update. |

## Reporting a vulnerability

**Please don't open a public issue, discussion or pull request for a vulnerability.**

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/argahv/notchflow/security/advisories/new)
(or the repository's **Security** tab, then **Report a vulnerability**). Only the maintainer can see the
report, and you can work on the advisory and a fix together there.

Please include:

- The affected version or commit, and your macOS version and Mac model.
- What an attacker can do, and what they need first (for example "another local user", "a malicious
  web page", "a process already running as you").
- Steps to reproduce, or a proof of concept.
- Any suggested fix.

What to expect: the maintainer is one person, so these are goals rather than guarantees. You should get an
acknowledgement within 7 days and an assessment within 14 days. Fixes are released as soon as they're
ready, and you'll be credited in the advisory unless you'd rather not be.

## Scope

In scope, for example:

- The event inbox, approval files and agent hooks (`Scripts/notchflow.py`, `Sources/NotchFlow/Features/EventBridge.swift`,
  `Sources/NotchFlow/Features/AgentApprovals.swift`): injection by another user, replayed or forged
  approvals, symlink or permission bugs, request text leaking into History.
- Anything that sends data off the Mac beyond what [the privacy docs](docs/security/integrations.md) describe.
- Clipboard capture of content that should have been skipped (password managers, concealed types).
- URL handling in actions and notifications (schemes other than those documented).
- Handling of the GitHub token (Keychain storage, where it's sent).
- File handling in the shelf, Notch Actions and screenshots (writing, moving or deleting files it shouldn't).

Out of scope:

- Attacks that need a process already running as your macOS user. That process can act as you directly;
  see the [trust boundary](docs/security/integrations.md#trust-boundary).
- The best-effort "looks like a secret" clipboard check missing a secret. That's documented, but better
  patterns are welcome as a normal pull request.
- Unsigned development builds and CI artifacts, which aren't distributed as releases.

## For contributors

- Never commit tokens, certificates, `.p12`/`.p8` files, notarization profiles or personal paths. Release
  secrets live only in GitHub Actions secrets (see [releasing](docs/RELEASING.md)).
- Code that reads agent hook input must not publish `prompt`, `last_assistant_message`, `tool_input`,
  `tool_response` or `transcript_path`.
- New network requests, new macOS permissions or new entitlements need to be called out in the pull
  request and documented in [docs/security/integrations.md](docs/security/integrations.md).
