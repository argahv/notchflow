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
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["overlayEnabled": true, "simulatedNotch": true,
                                    "bridgeEnabled": true, "notchWidth": 190.0, "hoverDelay": 0.12,
                                    "showBattery": true, "historyRetentionDays": 30,
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
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
}

enum AppFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchFlow", isDirectory: true)
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
