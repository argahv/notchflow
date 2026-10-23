import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Obsidian & Silver. Nearly monochrome, like the hardware: black glass, graphite controls, silver
/// light. Colour only carries meaning: blue for the primary or selected action, green for success,
/// amber for something waiting on you, red for a genuine failure. Artwork and app icons keep theirs.
enum Ink {
    /// Physical Black: the camera housing and the resting notch.
    static let void = Color(hex: 0x000000)
    /// The expanded surface.
    static let obsidian = Color(hex: 0x08090B)
    /// Carbon: inner backgrounds.
    static let surface = Color(hex: 0x111317)
    /// Graphite: controls and selected items.
    static let elevated = Color(hex: 0x202329)
    static let hover = Color(hex: 0x2A2E35)
    /// Titanium: separators and secondary surfaces.
    static let titanium = Color(hex: 0x525760)
    /// Silver: reflective highlights and neutral glyphs.
    static let silver = Color(hex: 0xC8CDD4)

    /// Ice White.
    static let primary = Color(hex: 0xF4F5F7)
    /// Muted Silver: metadata and secondary labels (≈6:1 on Carbon). `muted` (≈3.9:1) is for glyphs only.
    static let secondary = Color(hex: 0x9298A2)
    static let muted = Color(hex: 0x6E747E)
    static let disabled = Color(hex: 0x4A4F57)

    static let accent = Color(hex: 0x0A84FF)
    static let green = Color(hex: 0x30D158)
    static let amber = Color(hex: 0xFFB340)
    static let red = Color(hex: 0xFF453A)
}

enum Tone: Equatable {
    case accent, silver, green, amber, red, neutral
    var color: Color {
        switch self {
        case .accent: Ink.accent
        case .silver: Ink.silver
        case .green: Ink.green
        case .amber: Ink.amber
        case .red: Ink.red
        case .neutral: Ink.secondary
        }
    }
}

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    static let xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
}

enum Radius {
    static let control: CGFloat = 9
    static let card: CGFloat = 14
    static let capsule: CGFloat = 22
    static let workspace: CGFloat = 28
}

enum TypeScale {
    static let title = Font.system(size: 18, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 11.5)
    static let meta = Font.system(size: 11, weight: .medium)
    static let badge = Font.system(size: 10.5, weight: .semibold)
    static let timer = Font.system(size: 28, weight: .medium, design: .rounded).monospacedDigit()
    static let numeral = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
}

extension ActivityPhase {
    var tone: Tone {
        switch self {
        case .waiting: .amber
        case .failed: .red
        case .completed: .green
        case .cancelled: .neutral
        case .started, .progress: .silver
        }
    }
    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "minus.circle"
        case .started, .progress: "circle.dotted"
        }
    }
    var label: String { rawValue.capitalized }
}

extension ActivityState {
    var tone: Tone {
        switch self {
        case .needsInput, .waiting: .amber
        case .failed: .red
        case .completed: .green
        case .running, .starting: .silver
        case .queued, .paused, .cancelled, .unknown: .neutral
        }
    }
    var symbol: String {
        switch self {
        case .needsInput: "hand.raised.fill"
        case .waiting: "ellipsis.bubble.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "minus.circle"
        case .paused: "pause.circle"
        case .queued: "clock"
        case .running, .starting, .unknown: "circle.dotted"
        }
    }
    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .paused: "Paused"
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .unknown: "Unknown"
        }
    }
}

extension AttentionPriority {
    var tone: Tone {
        switch self {
        case .critical: .red
        case .actionRequired: .amber
        case .informational: .green
        case .background: .silver
        case .silent: .neutral
        }
    }

    var dockBadgeAccessibilityValue: String {
        switch self {
        case .critical: "Failure"
        case .actionRequired: "Needs you"
        case .informational: "Completed"
        case .background, .silent: ""
        }
    }
}

/// A recognizable glyph for an event: its declared category first, then its free-form source name.
enum SourceGlyph {
    static func symbol(for event: ActivityEvent) -> String {
        switch event.category {
        case .agent: "sparkles"
        case .ci: "arrow.triangle.branch"
        case .build: "hammer"
        case .deploy: "shippingbox"
        case .download: "arrow.down.circle"
        case .timer: "timer"
        case .meeting: "video"
        case .system: "gearshape"
        case .task, nil: symbol(for: event.source)
        }
    }
    static func symbol(for source: String) -> String {
        let words = Set(source.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        func has(_ candidates: String...) -> Bool { !words.isDisjoint(with: candidates) }
        if has("claude", "agent", "ai", "codex", "copilot") { return "sparkles" }
        if has("deploy", "release", "staging", "production") { return "shippingbox" }
        if has("test", "tests") { return "checklist" }
        if has("ci", "build", "make", "xcode") { return "hammer" }
        if has("timer", "focus") { return "timer" }
        if has("terminal", "shell", "zsh", "bash") { return "terminal" }
        return "bolt.horizontal"
    }
}

extension AgentState {
    /// Labels only for what the provider's events justify; "working" follows a submitted prompt.
    func label(tool: String?) -> String {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting"
        case .working: "Working"
        case .executingTool: tool.map { "Running \($0)" } ?? "Running a tool"
        case .waitingForUser: "Waiting for you"
        case .awaitingAuthorization: tool.map { "Needs permission · \($0)" } ?? "Needs permission"
        case .completed: "Finished"
        case .failed: "Failed"
        case .disconnected: "Ended"
        case .unknown: "Unknown"
        }
    }
}

/// One-line descriptions shared by the glance, the stack and History.
enum ActivityText {
    static func subtitle(_ record: ActivityRecord) -> String {
        let event = record.event
        if let agent = event.agent, let state = agent.state {
            return [event.project, state.label(tool: agent.tool)].compactMap { $0 }.joined(separator: " · ")
        }
        // Downloads, meetings and system notices say what matters in their summary ("4.8 MB so far").
        if [.download, .meeting, .system].contains(event.kind), let summary = event.summary, !summary.isEmpty {
            return event.lifecycle.terminal ? "\(summary) · \(event.lifecycle.label)" : summary
        }
        return [event.source, event.branch, event.lifecycle.label].compactMap { $0 }.joined(separator: " · ")
    }
}
