import SwiftUI
import SwiftData

@Model final class Note {
    var id: UUID = UUID()
    var text: String = ""
    var updatedAt: Date = Date()
    init(text: String = "") { self.text = text }
}
@Model final class Todo {
    var id: UUID = UUID()
    var title: String = ""
    var completed: Bool = false
    var createdAt: Date = Date()
    init(title: String) { self.title = title }
}
@Model final class ShelfFile {
    var id: UUID = UUID()
    var name: String = ""
    var bookmark: Data = Data()
    var addedAt: Date = Date()
    // Added with the notch portal. Every field has a default, so stores from earlier versions open in
    // place and their items read as file references.
    /// See `ShelfKind`: the person's file by reference, a copy NotchFlow keeps, text, or a link.
    var kindRaw: String = "reference"
    /// Text, or a link's address.
    var text: String?
    /// The rich-text version of dropped text, when its source offered one.
    var richText: Data?
    /// A copy's path, relative to the shelf folder.
    var copyPath: String?
    var byteCount: Int?
    var contentType: String?
    /// How it arrived: `drop` or `picker`.
    var origin: String?
    /// Identity of text and links, to refuse a second copy of the same thing.
    var contentKey: String?
    init(name: String, bookmark: Data) { self.name = name; self.bookmark = bookmark }
}

enum VisualMode: String, CaseIterable { case performance = "Performance", balanced = "Balanced", ultra = "Ultra (experimental)" }
/// An installed application for the Quick apps launcher. Missing apps resolve to nil and are hidden.
struct QuickApp: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    init?(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        id = bundleID; self.url = url
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    func open() { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
}

@MainActor final class Preferences: ObservableObject {
    @Published var overlayEnabled: Bool { didSet { save("overlayEnabled", overlayEnabled) } }
    @Published var simulatedNotch: Bool { didSet { save("simulatedNotch", simulatedNotch) } }
    @Published var privacy: Bool { didSet { save("privacy", privacy) } }
    @Published var visualMode: VisualMode { didSet { save("visualMode", visualMode.rawValue) } }
    @Published var selectedDisplay: String { didSet { save("selectedDisplay", selectedDisplay) } }
    @Published var mediaPlayer: String { didSet { save("mediaPlayer", mediaPlayer) } }
    @Published var mediaEnabled: Bool { didSet { save("mediaEnabled", mediaEnabled) } }
    @Published var bridgeEnabled: Bool { didSet { save("bridgeEnabled", bridgeEnabled) } }
    @Published var quietMode: Bool { didSet { save("quietMode", quietMode) } }
    @Published var notchWidth: Double { didSet { save("notchWidth", notchWidth) } }
    @Published var shortcutName: String { didSet { save("shortcutName", shortcutName) } }
    /// Seconds the pointer rests on the notch before the glance opens.
    @Published var hoverDelay: Double { didSet { save("hoverDelay", hoverDelay) } }
    @Published var showBattery: Bool { didSet { save("showBattery", showBattery) } }
    /// Finished history older than this is pruned; 0 keeps everything (still capped at 200 records).
    @Published var historyRetentionDays: Int { didSet { save("historyRetentionDays", historyRetentionDays) } }
    @Published var quickApps: [String] { didSet { save("quickApps", quickApps) } }
    /// Off by default: agent hooks wait briefly for an Allow or Deny from the notch.
    @Published var agentApprovals: Bool { didSet { save("agentApprovals", agentApprovals) } }
    /// Seconds a hook waits for an answer before the agent's own prompt takes over.
    @Published var approvalWait: Int { didSet { save("approvalWait", approvalWait) } }
    /// `owner/name` repositories whose GitHub Actions runs appear in the stack.
    @Published var githubRepositories: [String] { didSet { save("githubRepositories", githubRepositories) } }
    @Published var githubEnabled: Bool { didSet { save("githubEnabled", githubEnabled) } }
    /// Off by default. Text only, in memory, never written to disk.
    @Published var clipboardEnabled: Bool { didSet { save("clipboardEnabled", clipboardEnabled) } }
    @Published var clipboardRetentionHours: Int { didSet { save("clipboardRetentionHours", clipboardRetentionHours) } }
    @Published var downloadsEnabled: Bool { didSet { save("downloadsEnabled", downloadsEnabled) } }
    @Published var meetingsEnabled: Bool { didSet { save("meetingsEnabled", meetingsEnabled) } }
    @Published var lowBatteryAlerts: Bool { didSet { save("lowBatteryAlerts", lowBatteryAlerts) } }
    /// The app in front reorders the stack (never opens anything). See `ContextRules`.
    @Published var contextAware: Bool { didSet { save("contextAware", contextAware) } }
    /// The notch reacts to a drag heading for it and keeps what's dropped on the shelf. Off, a drop
    /// on the notch opens the shelf instead.
    @Published var portalEnabled: Bool { didSet { save("portalEnabled", portalEnabled) } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["overlayEnabled": true, "simulatedNotch": true, "portalEnabled": true,
                                    "bridgeEnabled": true, "notchWidth": 190.0, "hoverDelay": 0.12,
                                    "showBattery": false, "historyRetentionDays": 30, "approvalWait": 25, "clipboardRetentionHours": 24, "contextAware": true,
                                    "quickApps": ["com.apple.Terminal", "com.microsoft.VSCode", "com.apple.finder", "com.apple.Safari", "com.apple.Notes"]])
        overlayEnabled = defaults.bool(forKey: "overlayEnabled")
        simulatedNotch = defaults.bool(forKey: "simulatedNotch")
        privacy = defaults.bool(forKey: "privacy")
        visualMode = VisualMode(rawValue: defaults.string(forKey: "visualMode") ?? "") ?? .balanced
        selectedDisplay = defaults.string(forKey: "selectedDisplay") ?? ""
        mediaPlayer = defaults.string(forKey: "mediaPlayer") ?? "Music"
        mediaEnabled = defaults.bool(forKey: "mediaEnabled")
        bridgeEnabled = defaults.bool(forKey: "bridgeEnabled")
        quietMode = defaults.bool(forKey: "quietMode")
        notchWidth = defaults.double(forKey: "notchWidth")
        shortcutName = defaults.string(forKey: "shortcutName") ?? ""
        hoverDelay = defaults.double(forKey: "hoverDelay")
        showBattery = defaults.bool(forKey: "showBattery")
        historyRetentionDays = defaults.integer(forKey: "historyRetentionDays")
        quickApps = defaults.stringArray(forKey: "quickApps") ?? []
        agentApprovals = defaults.bool(forKey: "agentApprovals")
        approvalWait = defaults.integer(forKey: "approvalWait")
        githubRepositories = defaults.stringArray(forKey: "githubRepositories") ?? []
        githubEnabled = defaults.bool(forKey: "githubEnabled")
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        clipboardRetentionHours = defaults.integer(forKey: "clipboardRetentionHours")
        downloadsEnabled = defaults.bool(forKey: "downloadsEnabled")
        meetingsEnabled = defaults.bool(forKey: "meetingsEnabled")
        lowBatteryAlerts = defaults.bool(forKey: "lowBatteryAlerts")
        contextAware = defaults.bool(forKey: "contextAware")
        portalEnabled = defaults.bool(forKey: "portalEnabled")
    }

    var modeSettings: ModeSettings {
        ModeSettings(quietMode: quietMode, contextAware: contextAware, hoverDelay: hoverDelay, github: githubEnabled)
    }
    /// The preset these settings match, or nil when they've been customized.
    var mode: ProductMode? { ProductMode.matching(modeSettings) }
    func apply(_ mode: ProductMode) {
        let settings = mode.settings
        quietMode = settings.quietMode; contextAware = settings.contextAware
        hoverDelay = settings.hoverDelay; githubEnabled = settings.github
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}

enum AppFiles {
    static var root: URL {
        #if DEBUG
        // Scripted QA points a Debug build at a throwaway folder, so test drops never reach the real shelf.
        if let override = ProcessInfo.processInfo.environment["NOTCHFLOW_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchFlow", isDirectory: true)
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
