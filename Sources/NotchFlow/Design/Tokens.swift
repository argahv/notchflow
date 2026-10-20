import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Obsidian Liquid palette. Colour is functional: iris marks interaction and selection, mint success
/// and live status, amber waiting, coral genuine failure, blue information. Never decoration.
enum Ink {
    static let void = Color(hex: 0x08090D)
    static let obsidian = Color(hex: 0x0D0F14)
    static let surface = Color(hex: 0x15171E)
    static let elevated = Color(hex: 0x1D2029)
    static let hover = Color(hex: 0x282B36)

    static let primary = Color(hex: 0xF2F2F7)
    /// Metadata and secondary labels; ≈7:1 on `surface`. `muted` (≈4:1) is for glyphs and inactive chrome only.
    static let secondary = Color(hex: 0xA0A3B1)
    static let muted = Color(hex: 0x707481)
    static let disabled = Color(hex: 0x555965)

    static let iris = Color(hex: 0xA99BFF)
    static let lavender = Color(hex: 0xC5BAFF)
    static let mint = Color(hex: 0x73E0BD)
    static let amber = Color(hex: 0xFFBE76)
    static let coral = Color(hex: 0xFF858F)
    static let blue = Color(hex: 0x82B8FF)
}

enum Tone: Equatable {
    case iris, mint, amber, coral, blue, neutral
    var color: Color {
        switch self {
        case .iris: Ink.iris
        case .mint: Ink.mint
        case .amber: Ink.amber
        case .coral: Ink.coral
        case .blue: Ink.blue
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
        case .failed: .coral
        case .completed: .mint
        case .cancelled: .neutral
        case .started, .progress: .blue
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
        case .failed: .coral
        case .completed: .mint
        case .running, .starting: .blue
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
        case .critical: .coral
        case .actionRequired: .amber
        case .informational: .mint
        case .background: .blue
        case .silent: .neutral
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
        return [event.source, event.branch, event.lifecycle.label].compactMap { $0 }.joined(separator: " · ")
    }
}
