import Foundation

/// A macOS privacy permission a capability relies on.
public enum SystemPermission: String, Sendable, CaseIterable {
    case calendar, reminders, filesAndFolders, screenRecording, automation, camera
    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .filesAndFolders: "Files and Folders"
        case .screenRecording: "Screen Recording"
        case .automation: "Automation"
        case .camera: "Camera"
        }
    }
}

/// One thing NotchFlow can observe or do with your data, described plainly: what, why, where it goes,
/// which permission it needs, how to stop it and how to clear what it kept.
public struct PrivacyEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let observes: String
    public let purpose: String
    /// What leaves this Mac, or nil when nothing does.
    public let leavesMac: String?
    public let permission: SystemPermission?
    public let storage: String
    public let turnOff: String
    public let clear: String
    /// Context sources this capability feeds.
    public let sources: Set<ContextSource>
    public let onByDefault: Bool
}

public enum PrivacyCatalog {
    public static let entries: [PrivacyEntry] = [
        PrivacyEntry(id: "context.app", title: "App in front",
                     observes: "Which app you switch to: its name and bundle identifier. Never window titles or what's on screen.",
                     purpose: "Ranks agents and builds higher in a terminal, downloads in a browser, and gives suggestions context, for example not offering to open a link you copied in a browser.",
                     leavesMac: nil, permission: nil, storage: "Memory only: the current app.",
                     turnOff: "Settings › Mode › Follow the app in front, and Settings › Suggestions.", clear: "Nothing is kept.",
                     sources: [.frontmostApp], onByDefault: true),
        PrivacyEntry(id: "clipboard.history", title: "Clipboard history",
                     observes: "Text you copy. Copies from password managers, copies marked concealed, apps you exclude and text that looks like a key are skipped; that last check is best effort.",
                     purpose: "Lists what you copied in Tools › Clipboard.",
                     leavesMac: nil, permission: nil, storage: "Memory only, gone when NotchFlow quits, and pruned after the time you choose.",
                     turnOff: "Settings › Clipboard, downloads and meetings › Clipboard history.", clear: "Tools › Clipboard › Clear, or turn it off.",
                     sources: [.clipboard], onByDefault: false),
        PrivacyEntry(id: "clipboard.suggestions", title: "Suggestions from what you copy",
                     observes: "The same filtered copies, read once to choose a suggestion, and the app you copied in.",
                     purpose: "Offers one next step for a link, color, JSON, address, date, email address, phone number, file path or long passage.",
                     leavesMac: nil, permission: nil,
                     storage: "The copy is held in memory only while its suggestion is showing. Learning keeps counts per kind of suggestion on this Mac, never what you copied.",
                     turnOff: "Settings › Suggestions › Suggest from what you copy.", clear: "Settings › Suggestions › Reset Learning.",
                     sources: [.clipboard], onByDefault: false),
        PrivacyEntry(id: "downloads", title: "Download Center",
                     observes: "File names and sizes in your Downloads folder.",
                     purpose: "Shows downloads in progress and the finished file.",
                     leavesMac: nil, permission: .filesAndFolders, storage: "Activity History on this Mac, pruned by your history setting.",
                     turnOff: "Settings › Clipboard, downloads and meetings › Download Center.", clear: "History › Clear.",
                     sources: [], onByDefault: false),
        PrivacyEntry(id: "screenshots", title: "Screenshots",
                     observes: "New files macOS marks as screenshots in your screenshot folder. Text is read on this Mac only when you ask.",
                     purpose: "Shows each new screenshot with Copy, Extract Text and Annotate.",
                     leavesMac: nil, permission: .filesAndFolders, storage: "Memory only. Screenshots stay where macOS saved them.",
                     turnOff: "Settings › Screenshots.", clear: "Nothing is kept.", sources: [], onByDefault: false),
        PrivacyEntry(id: "meetings", title: "Meeting reminders",
                     observes: "Calendar events in the next day that have a call link.",
                     purpose: "Shows a call ten minutes early with Join.",
                     leavesMac: nil, permission: .calendar, storage: "The meeting's title and time in Activity History.",
                     turnOff: "Settings › Clipboard, downloads and meetings › Meeting reminders.", clear: "History › Clear.",
                     sources: [], onByDefault: false),
        PrivacyEntry(id: "reminders", title: "Reminders from suggestions",
                     observes: "Nothing. A reminder is written only when you choose Remind Me.",
                     purpose: "Adds a reminder for a date you copied.",
                     leavesMac: nil, permission: .reminders, storage: "In Reminders, like any reminder you add.",
                     turnOff: "Settings › Suggestions › Dates.", clear: "Undo right after adding it, or delete it in Reminders.",
                     sources: [], onByDefault: false),
        PrivacyEntry(id: "agents", title: "Agent and build events",
                     observes: "Status your tools send to NotchFlow's local inbox: state, tool name, project and branch. Never prompts, replies or tool input.",
                     purpose: "Follows agents, builds and scripts, and answers permission requests when you allow that.",
                     leavesMac: nil, permission: nil, storage: "Activity History on this Mac. A pending request's command is kept only while it waits.",
                     turnOff: "Settings › Integrations › Accept local agent and build events.", clear: "History › Clear.",
                     sources: [], onByDefault: true),
        PrivacyEntry(id: "github", title: "GitHub Actions",
                     observes: "Workflow runs for the repositories you add.",
                     purpose: "Shows running and failed runs in the stack.",
                     leavesMac: "Read-only requests to api.github.com for those repositories, with your token if you saved one.",
                     permission: nil, storage: "Token in your login Keychain; runs in Activity History.",
                     turnOff: "Settings › GitHub Actions.", clear: "Remove the token in Settings; History › Clear.",
                     sources: [], onByDefault: false),
        PrivacyEntry(id: "linkTitle", title: "Fetch Title",
                     observes: "Nothing in the background.",
                     purpose: "Reads a link's page title when you choose Fetch Title.",
                     leavesMac: "One request to that link's website, only when you choose it.",
                     permission: nil, storage: "Nothing is kept.", turnOff: "Don't choose it.", clear: "Nothing is kept.",
                     sources: [], onByDefault: true),
        PrivacyEntry(id: "media", title: "Music and Spotify",
                     observes: "What Music or Spotify is playing, while the Music view is open.",
                     purpose: "Shows the track and transport controls.",
                     leavesMac: nil, permission: .automation, storage: "Memory only.",
                     turnOff: "Settings › Integrations › Music / Spotify controls.", clear: "Nothing is kept.",
                     sources: [], onByDefault: false),
        PrivacyEntry(id: "sound", title: "Sound output",
                     observes: "Which audio output is active, from Core Audio. No permission and no microphone.",
                     purpose: "Shows AirPods or speakers connecting, with volume and a quick switch.",
                     leavesMac: nil, permission: nil, storage: "Memory only.",
                     turnOff: "Settings › Integrations › Show when sound changes output.", clear: "Nothing is kept.",
                     sources: [], onByDefault: true),
        PrivacyEntry(id: "ultra", title: "Ultra visuals",
                     observes: "The screen area behind the open notch, ten times a second, while it's open.",
                     purpose: "Refracts what's behind the glass.",
                     leavesMac: nil, permission: .screenRecording, storage: "Frames are never saved.",
                     turnOff: "Settings › Appearance › Surface.", clear: "Nothing is kept.", sources: [], onByDefault: false),
        PrivacyEntry(id: "camera", title: "Mirror",
                     observes: "Your camera, only while Tools › Mirror is open.",
                     purpose: "A quick look at yourself before a call.",
                     leavesMac: nil, permission: .camera, storage: "Frames are never saved.",
                     turnOff: "Close Mirror.", clear: "Nothing is kept.", sources: [], onByDefault: false),
        PrivacyEntry(id: "shelf", title: "Shelf",
                     observes: "Only what you drop on the notch or pick.",
                     purpose: "Keeps files, links and text within reach and runs Notch Actions on them.",
                     leavesMac: nil, permission: nil,
                     storage: "On this Mac: references to your files, plus copies of images and attachments that had no file of their own.",
                     turnOff: "Settings › Workspace › Drop anything on the notch.", clear: "Shelf › Clear.",
                     sources: [], onByDefault: true),
    ]

    public static func entry(_ id: String) -> PrivacyEntry? { entries.first { $0.id == id } }
}
