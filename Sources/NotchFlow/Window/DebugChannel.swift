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
            } else if argument.hasPrefix("safari:") {
                model.clipboard.consider(String(argument.dropFirst(7)), types: [], app: "com.apple.Safari", appName: "Safari")
            } else if argument.hasPrefix("concealed:") {
                model.clipboard.consider(String(argument.dropFirst(10)), types: ["org.nspasteboard.ConcealedType"], app: nil, appName: nil)
            } else {
                model.clipboard.consider(argument.replacingOccurrences(of: "\\n", with: "\n"), types: [], app: "com.apple.dt.Xcode", appName: "Xcode")
            }
        case "suggest":
            // "suggest:on|off" (copy suggestions), "suggest:run:<index>", "suggest:why", "suggest:dismiss", "suggest:undo",
            // "suggest:reset" (learning), "suggest:sensitivity:<fewer|balanced|more>".
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first {
            case "on": model.preferences.suggestionsEnabled = true; model.preferences.clipboardSuggestions = true
            case "off": model.preferences.clipboardSuggestions = false
            case "run":
                if let index = parts.count > 1 ? Int(parts[1]) : 0, let actions = model.suggestion?.actions, actions.indices.contains(index) {
                    model.runSuggestion(actions[index])
                }
            case "why": model.toggleSuggestionWhy()
            case "dismiss": model.dismissSuggestion()
            case "undo": model.undoSuggestion()
            case "reset": model.resetSuggestionLearning()
            case "sensitivity": if parts.count > 1, let value = SuggestionSensitivity(rawValue: parts[1]) { model.preferences.suggestionSensitivity = value }
            default: break
            }
        case "privacy": model.preferences.privacy = argument == "on"
        case "front":
            // "front:<bundle id>|<name>": the app in front, through the same gate as the real observer; real
            // activations are ignored from then on. "front:real" hands the source back to the real observer.
            if argument == "real" { model.contextEngine.debugScripted.remove(.frontmostApp); break }
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            model.contextEngine.debugEmit(.frontmostApp(bundleID: parts.first, name: parts.count > 1 ? parts[1] : nil))
        case "mode":
            // "mode:pin:<mode>", "mode:auto", "mode:follow:on|off", "mode:settle:<seconds>".
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first {
            case "pin": if parts.count > 1, let mode = WorkMode(rawValue: parts[1]) { model.preferences.pinnedWorkMode = mode }
            case "auto": model.preferences.pinnedWorkMode = nil
            case "follow": model.preferences.workModesEnabled = parts.count > 1 && parts[1] == "on"
            case "settle": if parts.count > 1, let seconds = Double(parts[1]) { model.debugSetModeSettle(seconds) }
            default: break
            }
        case "nowplaying":
            // "nowplaying:<title>|<artist>" or "nowplaying:off"
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            model.media.debugNowPlaying(title: argument == "off" ? nil : parts.first, artist: parts.count > 1 ? parts[1] : "")
            model.reflow()
        case "hoverOpen":
            // Same handlers the preview's buttons call: "primary" (single or the split's work side),
            // "ambient" (the split's left side), "count" (the +N chip).
            switch (argument, model.glanceLead) {
            case ("primary", .single(let item, _)), ("primary", .split(_, let item, _)), ("ambient", .split(let item, _, _)):
                model.openHoverItem(item)
            case ("count", _): model.navigate(.activity(detail: nil))
            default: break
            }
        case "clearActivities":
            model.clearHistory(); model.reflow()
        case "portal":
            // "portal:near:<kind>:<count>", "portal:close:<kind>:<count>", "portal:enter", "portal:exit",
            // "portal:away". Drives the same calls the drag monitor and the drop target make.
            let parts = argument.split(separator: ":").map(String.init)
            let cargo = parts.count > 1 ? PortalCargo(kind: PortalContentKind(rawValue: parts[1]) ?? .file,
                                                      count: parts.count > 2 ? Int(parts[2]) ?? 1 : 1) : nil
            switch parts.first {
            case "near": model.dragProximity(.near, cargo: cargo)
            case "close": model.dragProximity(.close, cargo: cargo)
            case "enter": model.dragEntered(cargo ?? model.portalCargo)
            case "exit": model.dragExited()
            default: model.dragProximity(.away, cargo: nil)
            }
        case "drop":
            // "drop:file:<path>|<path>", "drop:text:<text>", "drop:link:<url>": the drop path after the pasteboard.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "file": model.keep(value.split(separator: "|").map { .reference(URL(fileURLWithPath: String($0))) })
            case "text": model.keep([.text(value.replacingOccurrences(of: "\\n", with: "\n"), rich: nil)])
            case "link": model.keep(ShelfPolicy.link(from: value).map { [.link($0)] } ?? [])
            default: break
            }
        case "pasteboard":
            // "pasteboard:<name>": a named pasteboard another process filled, read exactly as a drop is.
            guard !argument.isEmpty else { break }
            _ = model.receiveDrop(NSPasteboard(name: NSPasteboard.Name(argument)), sequence: Int.random(in: 1...Int.max))
        case "sound":
            // "sound:connected:<name>" or "sound:switched:<name>": the glance a real output change would show.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { break }
            model.soundChanged(parts[0] == "connected" ? .connected(name: parts[1]) : .switched(name: parts[1], bluetooth: false))
        case "timeline":
            // "timeline:open", "timeline:move:<steps>" (positive is earlier), "timeline:now".
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first {
            case "open": model.openTimeline()
            case "move": model.moveTimeline(Int(parts.count > 1 ? parts[1] : "1") ?? 1)
            case "now": model.timelineToPresent()
            default: break
            }
        case "split":
            // "split:next:primary|secondary", "split:prev:…", "split:pin:<hover id>" (music, timer, or an activity id).
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "next", "prev": model.cycleHover(value == "secondary" ? .secondary : .primary, step: parts.first == "next" ? 1 : -1)
            case "pin": if let item = model.hoverItem(id: value) { model.toggleHoverPin(item) }
            default: break
            }
        case "screenshots":
            // "screenshots:watch" / "screenshots:stop": the watcher only, without changing the saved setting.
            model.screenshots.configure(enabled: argument == "watch")
        case "capture":
            // "capture:<path>" (as if that file were just detected), "capture:text", "capture:annotate",
            // "capture:dismiss".
            switch argument {
            case "text": model.readCaptureText()
            case "annotate": model.annotateCapture()
            case "dismiss": model.dismissCapture()
            default: if argument.hasPrefix("/") { model.screenshots.deliver(URL(fileURLWithPath: argument), taken: Date()) }
            }
        case "annotate":
            // "annotate:<tool>:x1,y1,x2,y2[:text]" with fractions of the image, or undo, redo, clear, save.
            let parts = argument.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.first {
            case "undo": model.changeAnnotations { $0.undo() }
            case "redo": model.changeAnnotations { $0.redo() }
            case "clear": model.changeAnnotations { $0.clear() }
            case "save": model.saveAnnotatedCopy()
            default:
                guard let tool = parts.first.flatMap(AnnotationTool.init(rawValue:)), parts.count > 1 else { break }
                let n = parts[1].split(separator: ",").compactMap { Double($0) }
                guard n.count == 4 else { break }
                let item = Annotation(tool: tool, start: AnnotationPoint(x: n[0], y: n[1]), end: AnnotationPoint(x: n[2], y: n[3]),
                                      text: parts.count > 2 ? parts[2] : nil)
                model.changeAnnotations { $0.add(item) }
            }
        case "actions":
            // "actions:<item name prefix>[:<action>]", or "actions:pdfs:mergePDFs" for every PDF on the shelf;
            // "actions:cancel", "actions:undo".
            let parts = argument.split(separator: ":").map(String.init)
            switch parts.first {
            case "cancel": model.cancelAction()
            case "undo": model.undoAction()
            case "pdfs":
                let ids = model.shelf.items.filter { $0.name.lowercased().hasSuffix(".pdf") }.map(\.id)
                model.openActions(ids, then: parts.count > 1 ? ContentAction(rawValue: parts[1]) : nil)
            default:
                guard let prefix = parts.first, let item = model.shelf.items.first(where: { $0.name.hasPrefix(prefix) }) else { break }
                model.openActions([item.id], then: parts.count > 1 ? ContentAction(rawValue: parts[1]) : nil)
            }
        case "shelf":
            switch argument {
            case "clear": model.clearShelf()
            case "undo": model.undoShelfRemoval()
            default: break
            }
        case "snapshot":
            // "snapshot:<name>" or "snapshot:<name>:light"
            let parts = argument.split(separator: ":").map(String.init)
            if let name = parts.first, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                windows.snapshot(to: AppFiles.root.appendingPathComponent("debug/\(name).png"), light: parts.dropFirst().first == "light")
            }
        case "status":
            let lines = model.providers.statuses.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.label)" }
                + ["route: \(model.route) · \(model.interaction.presentation)",
                   "hover: \(model.hoverChoice.primary?.id ?? "-") + \(model.hoverChoice.secondary?.id ?? "-") +\(model.hoverChoice.others) · pin: \(model.hoverPin ?? "-")",
                   "context: \(model.contextBoost.map(\.rawValue).sorted().joined(separator: ","))",
                   "portal: \(model.interaction.portal.rawValue) · awareness: \(model.interaction.awareness.rawValue) · shelf: \(model.shelfCount)",
                   "portal result: \(model.portalResult.map { "\($0.title) — \($0.detail)" } ?? "-")",
                   "screenshots: \(model.screenshots.status)",
                   "capture: \(model.capture.map { "\($0.id.uuidString.prefix(8)) \($0.name) \(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "-") · glance: \(model.glance)",
                   "capture text: \(model.captureText)",
                   "action context: \(model.actionContext.map { "\($0.kind.rawValue) \($0.title) pages=\($0.pageCount.map(String.init) ?? "-") sensitive=\($0.sensitive)" } ?? "-")",
                   "action: \(model.actionRun.phase) · created: \(model.actionCreated.count)",
                   "portal actions: \(model.portalResult?.actions.map(\.rawValue).joined(separator: ",") ?? "-")",
                   "agent pulse: \(model.agentPulse?.rawValue ?? "-")",
                   "sound: \(model.sound.output?.name ?? "-") · volume \(model.sound.volume.map { String(format: "%.2f", $0) } ?? "-") · muted \(model.sound.muted.map(String.init) ?? "-") · bluetooth \(model.sound.bluetooth) · glance \(model.glance == .sound)",
                   "timeline: \(model.timeline.count) · at \(model.timelineCursor.index): \(model.timelineEntry.map { "\($0.kind.rawValue) \($0.title)" } ?? "-") · actions: \(model.timelineEntry.map { model.timelineActions($0).map(\.title).joined(separator: ",") } ?? "-")",
                   "celebration: \(model.celebration.map { "\($0.title) — \($0.detail) (\($0.batch.count))" } ?? "-")",
                   "annotations: \(model.annotations.items.map(\.tool.rawValue).joined(separator: ",")) · saved: \(model.annotatedCopy?.lastPathComponent ?? "-")",
                   "mode: \(model.preferences.mode?.title ?? "Custom")",
                   "suggestion: \(model.suggestion.map { "\($0.rule) · \($0.title) · \($0.actions.map(\.title).joined(separator: ",")) · score \(String(format: "%.2f", $0.score))" } ?? "-") · pending \(model.pendingSuggestion?.rule ?? "-") · why \(model.suggestionWhy) · result \(model.suggestionResult.map { "\($0.title) — \($0.detail ?? "") undo=\($0.canUndo)" } ?? "-")",
                   "context sources: " + ContextSource.allCases.map { source in
                       let state = model.contextEngine.states[source]
                       return "\(source.rawValue)=\(state?.running == true ? "on" : "off")/\(state?.delivered ?? 0)/\(state?.coalesced ?? 0)"
                   }.joined(separator: " "),
                   "inspector: " + model.contextEngine.log.prefix(6).map(\.text).joined(separator: " | "),
                   "learning: " + model.learnedRules.sorted { $0.key < $1.key }.map { "\($0.key) +\($0.value.accepted) -\($0.value.dismissed) ~\($0.value.ignored)" }.joined(separator: ", "),
                   "clipboard: history \(model.clipboard.enabled) · items \(model.clipboard.items.count) · skipped \(model.clipboard.skipped)",
                   "waiting: " + model.waitingGlances.map { "\($0.kind.rawValue)/\($0.tier.title)" }.joined(separator: ","),
                   "work mode: \(model.workMode.rawValue) · \(model.workModeReason) · pending \(model.pendingModeReading?.mode.rawValue ?? "-") · shortcuts \(model.workMode.shortcuts.map(\.rawValue).joined(separator: ",")) · line \(model.showsModeLine)"]
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
