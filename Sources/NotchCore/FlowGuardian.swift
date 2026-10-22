import Foundation

// Flow Guardian: while a focus session runs, only work that needs the person comes through. Everything
// else waits quietly and is counted, so the end of the session can say what waited instead of replaying it.
// It covers NotchFlow's own previews only; macOS gives no app a way to read or hold other apps' notifications.

public enum FlowGuardian {
    /// The lowest priority that still comes through during a focus session: needs-input and failures.
    public static let lowestPriorityDuringFocus = AttentionPriority.actionRequired
}

/// What waited during one focus session. Memory only, and only what the summary needs.
public struct FocusLedger: Sendable {
    public enum Kind: String, Sendable { case update, suggestion }
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let title: String
    }

    public private(set) var started: Date?
    public private(set) var entries: [Entry] = []
    private var pausedAt: Date?
    private var pausedFor: TimeInterval = 0
    public init() {}

    public var active: Bool { started != nil }
    /// Holding things back: in a session and not paused.
    public var focusing: Bool { started != nil && pausedAt == nil }

    /// A new session starts with an empty ledger.
    public mutating func begin(at date: Date) {
        started = date; entries = []; pausedAt = nil; pausedFor = 0
    }
    public mutating func pause(at date: Date) { if focusing { pausedAt = date } }
    public mutating func resume(at date: Date) {
        guard let pausedAt else { return }
        pausedFor += max(0, date.timeIntervalSince(pausedAt)); self.pausedAt = nil
    }

    /// Notes something that waited. The same update arriving again counts once.
    public mutating func note(id: String, kind: Kind, title: String) {
        guard active, !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(id: id, kind: kind, title: title))
    }

    /// Ends the session and says what it was, or nil when none was running.
    public mutating func end(at date: Date, completed: Bool) -> FocusSummary? {
        guard let started else { return nil }
        resume(at: date)
        let summary = FocusSummary(focused: max(0, date.timeIntervalSince(started) - pausedFor), completed: completed,
                                   updates: entries.filter { $0.kind == .update }.map(\.id),
                                   suggestions: entries.filter { $0.kind == .suggestion }.count)
        self = FocusLedger()
        return summary
    }
}

public struct FocusSummary: Equatable, Sendable {
    /// Time spent focusing, without pauses.
    public let focused: TimeInterval
    public let completed: Bool
    /// The activity ids that waited, so they aren't replayed one by one afterwards.
    public let updates: [String]
    public let suggestions: Int

    public var waited: Int { updates.count + suggestions }
    public var title: String { completed ? "Focus session finished" : "Focus session ended early" }

    /// "25 min · 3 updates and 1 suggestion waited", or "25 min · nothing waited".
    public var detail: String {
        let minutes = max(1, Int((focused / 60).rounded()))
        let time = minutes >= 60 ? "\(minutes / 60) h" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "") : "\(minutes) min"
        let count = updates.count
        var parts: [String] = []
        if count > 0 { parts.append("\(count) \(count == 1 ? "update" : "updates")") }
        if suggestions > 0 { parts.append("\(suggestions) \(suggestions == 1 ? "suggestion" : "suggestions")") }
        return time + " · " + (parts.isEmpty ? "nothing waited" : parts.joined(separator: " and ") + " waited")
    }
}
