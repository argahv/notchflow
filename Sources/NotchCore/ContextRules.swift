import Foundation

/// Which kinds of activity the app in front makes more relevant. Deterministic and local: the
/// result only reorders the stack and the resting indicator; it never opens or expands anything.
public enum ContextRules {
    static let developer: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4", "com.panic.Nova",
        "com.anthropic.claudefordesktop", "com.openai.codex"
    ]
    static let developerPrefixes = ["com.jetbrains."]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
    ]
    static let meetings: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.iCal", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"
    ]

    public static func boost(forFrontmost bundleID: String?) -> Set<ActivityCategory> {
        guard let bundleID else { return [] }
        if developer.contains(bundleID) || developerPrefixes.contains(where: bundleID.hasPrefix) { return [.agent, .build, .ci, .deploy] }
        if browsers.contains(bundleID) { return [.download, .ci] }
        if meetings.contains(bundleID) { return [.meeting] }
        return []
    }
}

/// The settings a product mode sets. Applying a mode writes these once; anything changed later
/// makes the configuration "Custom" rather than being silently reverted. Features that need a
/// permission or data (clipboard, downloads, meetings) stay separate opt-ins.
public struct ModeSettings: Equatable, Sendable {
    public var quietMode: Bool
    public var showBattery: Bool
    public var contextAware: Bool
    public var hoverDelay: Double
    public var github: Bool
    public init(quietMode: Bool, showBattery: Bool, contextAware: Bool, hoverDelay: Double, github: Bool) {
        self.quietMode = quietMode; self.showBattery = showBattery; self.contextAware = contextAware
        self.hoverDelay = hoverDelay; self.github = github
    }
}

public enum ProductMode: String, CaseIterable, Identifiable, Sendable {
    case minimal, dynamic, developer
    public var id: String { rawValue }
    public var title: String {
        switch self { case .minimal: "Minimal"; case .dynamic: "Dynamic"; case .developer: "Developer" }
    }
    public var summary: String {
        switch self {
        case .minimal: "A quiet notch: no automatic previews, no battery, no context ranking. Open it when you want it."
        case .dynamic: "Previews for things that need you, and a stack that follows the app in front."
        case .developer: "Dynamic, plus GitHub Actions for the repositories you add. Agents and pipelines rank first while an editor or terminal is in front."
        }
    }
    public var settings: ModeSettings {
        switch self {
        case .minimal: ModeSettings(quietMode: true, showBattery: false, contextAware: false, hoverDelay: 0.25, github: false)
        case .dynamic: ModeSettings(quietMode: false, showBattery: true, contextAware: true, hoverDelay: 0.12, github: false)
        case .developer: ModeSettings(quietMode: false, showBattery: true, contextAware: true, hoverDelay: 0.12, github: true)
        }
    }
    /// The mode the current settings match exactly, or nil for a custom setup.
    public static func matching(_ settings: ModeSettings) -> ProductMode? {
        allCases.first { $0.settings == settings }
    }
}
