#if DEBUG
import AppKit

/// Debug builds only: scripted QA drives states the pointer can't reach from a test harness.
/// Drop a `*.cmd` file (one command per line, e.g. `open:tools.notes`, `event:enter`,
/// `reduceMotion:on`) into `~/Library/Application Support/NotchFlow/debug`. Uses the same
/// directory-watch transport as the activity inbox, which is reliable from any process.
@MainActor enum DebugChannel {
    private static var source: DispatchSourceFileSystemObject?

    static func install(model: AppModel, windows: WindowManager) {
        let folder = AppFiles.root.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        watcher.setEventHandler { MainActor.assumeIsolated { drain(folder, model: model, windows: windows) } }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
    }

    private static func drain(_ folder: URL, model: AppModel, windows: WindowManager) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "cmd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: file)
            for line in text.split(whereSeparator: \.isNewline) { run(String(line), model: model, windows: windows) }
        }
    }

    static func run(_ command: String, model: AppModel, windows: WindowManager) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? "", argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "event": if let event = event(argument) { model.send(event) }
        case "open": if let route = route(argument) { model.navigate(route); windows.focus() }
        case "back": model.back()
        case "close": windows.close()
        case "hover": if argument == "enter" { model.hoverBegan() } else { model.pointerLeft() }
        case "note": if argument == "new" { model.newNote() } else { model.closeNote() }
        case "detail": model.toggleDetail(argument)
        case "notification": if argument == "view" { model.viewNotificationDetails() } else { model.dismissNotification() }
        case "query": model.commandQuery = argument
        case "timer": if let minutes = Int(argument) { model.startTimer(minutes: minutes) } else { model.cancelTimer() }
        case "media": model.preferences.mediaEnabled = argument == "on"
        case "reduceMotion": UserDefaults.standard.set(argument == "on", forKey: "NotchFlowReduceMotion")
        case "quiet": model.preferences.quietMode = argument == "on"
        case "filter": if let filter = AppModel.ActivityFilter(rawValue: argument) { model.setFilter(filter) }
        case "hide": if let record = model.record(argument) { model.hideFromStack(record) }
        case "pinRecord": if let record = model.record(argument) { model.togglePin(record) }
        case "clip":
            // "clip:<text>" or "clip:1password:<text>" (as if copied in a password manager).
            if argument.hasPrefix("1password:") {
                model.clipboard.consider(String(argument.dropFirst(10)), types: [], app: "com.1password.1password", appName: "1Password")
            } else if argument.hasPrefix("concealed:") {
                model.clipboard.consider(String(argument.dropFirst(10)), types: ["org.nspasteboard.ConcealedType"], app: nil, appName: nil)
            } else {
                model.clipboard.consider(argument.replacingOccurrences(of: "\\n", with: "\n"), types: [], app: "com.apple.dt.Xcode", appName: "Xcode")
            }
        case "status":
            let lines = model.providers.statuses.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.label)" }
                + ["context: \(model.contextBoost.map(\.rawValue).sorted().joined(separator: ","))",
                   "mode: \(model.preferences.mode?.title ?? "Custom")"]
            try? lines.joined(separator: "\n").write(to: AppFiles.root.appendingPathComponent("debug/status.txt"), atomically: true, encoding: .utf8)
        case "dumpHooks":
            let folder = AppFiles.root.appendingPathComponent("debug", isDirectory: true)
            for (name, text) in [("claude.json", HookSetup.claude(wait: 25)), ("codex.json", HookSetup.codex(wait: 25)), ("notify.toml", HookSetup.codexNotify)] {
                try? text?.write(to: folder.appendingPathComponent("hooks-" + name), atomically: true, encoding: .utf8)
            }
        case "allow", "deny": if let record = model.record(argument) { model.answer(record, verb == "allow" ? .allow : .deny) }
        default: NSLog("NotchFlow debug: unknown command %@", command)
        }
    }

    private static func event(_ name: String) -> InteractionEvent? {
        switch name {
        case "enter": .enter
        case "leave": .leave
        case "expand": .expand
        case "dismiss": .dismiss
        case "pin": .togglePin
        case "approach": .approach
        case "dragApproach": .dragApproach
        case "retreat": .retreat
        case "beginEditing": .beginEditing
        case "endEditing": .endEditing
        default: nil
        }
    }

    private static func route(_ name: String) -> Route? {
        let parts = name.split(separator: ".").map(String.init)
        switch parts.first {
        case "activity": return .activity(detail: parts.count > 1 ? parts[1] : nil)
        case "music": return .music
        case "shelf": return .shelf
        case "tools": return .tools(parts.count > 1 ? Tool(rawValue: parts[1]) : nil)
        case "history": return .history(detail: nil)
        case "command": return .command
        default: return nil
        }
    }
}
#endif
