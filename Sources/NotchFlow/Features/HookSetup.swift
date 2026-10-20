import AppKit

/// Hook configuration for the user to merge into their own agent settings. NotchFlow never writes
/// `~/.claude/settings.json` or `~/.codex/hooks.json`; it only puts text on the pasteboard.
enum HookSetup {
    static var script: String? { Bundle.main.url(forResource: "notchflow", withExtension: "py")?.path }

    static func command(_ arguments: String) -> String? {
        guard let script else { return nil }
        return "python3 " + quoted(script) + " " + arguments
    }

    /// `~/.claude/settings.json`. Event names from code.claude.com/docs/en/hooks.
    static func claude(wait: Int) -> String? {
        guard let command = command("agent-hook --provider claude") else { return nil }
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                      "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
        // Status hooks run in the background so they never slow Claude down. PermissionRequest stays
        // synchronous: a background hook's answer arrives too late to decide anything.
        return json(events: events, command: command, background: { $0 != "PermissionRequest" }) { $0 == "PermissionRequest" ? wait + 5 : 10 }
    }

    /// `~/.codex/hooks.json`. Event names from Codex's hooks documentation; `Interrupt` and
    /// `SessionEnd` allow at most three seconds. Codex asks you to trust new hooks before they run.
    static func codex(wait: Int) -> String? {
        guard let command = command("agent-hook --provider codex") else { return nil }
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                      "Stop", "Interrupt", "SessionEnd"]
        return json(events: events, command: command) { event in
            switch event { case "PermissionRequest": wait + 5; case "Interrupt", "SessionEnd": 3; default: 10 }
        }
    }

    /// Completion-only alternative for Codex (`config.toml`); use it or the hooks, not both.
    static var codexNotify: String? {
        guard let script else { return nil }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "notify = [\"python3\", \"\(escaped)\", \"codex-notify\"]"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func json(events: [String], command: String, background: (String) -> Bool = { _ in false },
                             timeout: (String) -> Int) -> String? {
        var hooks: [String: Any] = [:]
        for event in events {
            var handler: [String: Any] = ["type": "command", "command": command, "timeout": timeout(event)]
            if background(event) { handler["async"] = true }
            hooks[event] = [["hooks": [handler]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
