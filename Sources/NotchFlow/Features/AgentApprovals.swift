import AppKit
import Darwin

/// Answers agent permission requests through the hooks' documented `PermissionRequest` decision
/// output. NotchFlow writes only two kinds of owner-only file: a presence file, so a hook knows the
/// app is running and opted in (and how long to wait), and one single-use response per request,
/// matched by its id and nonce. It never types into a terminal and never edits agent configuration.
/// If nobody answers in time, the hook prints nothing and the agent's own prompt decides.
@MainActor final class AgentApprovals {
    enum Decision: String { case allow, deny }
    static let waitRange = 10...55

    private let root: URL
    private var presence: URL { root.appendingPathComponent("agent-approvals.json") }
    private var responses: URL { root.appendingPathComponent("responses", isDirectory: true) }
    private(set) var enabled = false

    init(root: URL = AppFiles.root) { self.root = root }

    /// Publishes or withdraws the opt-in. Hooks also check that this process is still alive.
    func sync(enabled: Bool, wait: Int) {
        self.enabled = enabled
        guard enabled else { withdraw(); return }
        let seconds = min(max(wait, Self.waitRange.lowerBound), Self.waitRange.upperBound)
        do {
            try AppFiles.prepare()
            let body: [String: Any] = ["enabled": true, "pid": Int(getpid()), "wait": seconds]
            try Self.writePrivately(JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), to: presence)
            sweep()
        } catch { self.enabled = false }
    }

    func withdraw() { try? FileManager.default.removeItem(at: presence) }

    func respond(_ decision: Decision, to request: ActivityRequest, now: Date = Date()) throws {
        guard enabled else { throw EventError.invalid("Answering from NotchFlow is turned off in Settings.") }
        guard request.expiresAt > now else { throw EventError.invalid("That request expired. Answer it in the terminal.") }
        try prepareResponses()
        let body: [String: Any] = ["requestId": request.id, "nonce": request.nonce, "decision": decision.rawValue,
                                   "timestamp": now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))]
        // The id was validated as 32 lowercase hex characters, so it's a safe file name.
        try Self.writePrivately(JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
                                to: responses.appendingPathComponent(request.id + ".json"))
    }

    /// Removes responses a hook never collected because it had already timed out.
    func sweep(olderThan age: TimeInterval = 900) {
        let cutoff = Date().addingTimeInterval(-age)
        let files = (try? FileManager.default.contentsOfDirectory(at: responses, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func prepareResponses() throws {
        if (try? responses.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw EventError.invalid("Refusing a linked responses folder.")
        }
        try FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: responses.path)
    }

    /// Owner-only and atomic: a reader sees either nothing or the whole file.
    static func writePrivately(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw EventError.invalid("Couldn't write \(url.lastPathComponent).") }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        Darwin.close(descriptor)
        guard written == data.count, synced, Darwin.rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw EventError.invalid("Couldn't write \(url.lastPathComponent).")
        }
    }
}

/// The app hosting an agent session, from the hook's `terminal` field (a bundle identifier, or
/// `TERM_PROGRAM`). NotchFlow only brings that app forward; it can't select a tab or send input.
struct HostApp: Equatable {
    let url: URL
    let name: String

    private static let termPrograms = [
        "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm", "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable",
        "zed": "dev.zed.Zed"
    ]
    @MainActor private static var cache: [String: HostApp?] = [:]

    @MainActor static func resolve(_ identifier: String?) -> HostApp? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if let cached = cache[identifier] { return cached }
        let bundleID = identifier.contains(".") && termPrograms[identifier] == nil ? identifier : termPrograms[identifier]
        let resolved = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { url in
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return HostApp(url: url, name: name)
        }
        cache[identifier] = resolved
        return resolved
    }

    func activate() { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
}
