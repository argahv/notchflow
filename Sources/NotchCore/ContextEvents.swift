import Foundation

// The Context Engine's vocabulary: what was observed, where it came from and how private it is, plus the
// gate that coalesces bursts. Pure and deterministic, so it's tested without NSWorkspace or a pasteboard.

/// Where a signal came from: one case per observer that exists, so nothing here describes a source that
/// isn't wired.
public enum ContextSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case frontmostApp, clipboard
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .frontmostApp: "App in front"
        case .clipboard: "Clipboard"
        }
    }
}

/// How private a signal is, which decides where it may go.
public enum PrivacyClass: Int, Comparable, Codable, Sendable {
    /// Machine state with nothing personal in it (a display, power).
    case system
    /// What the person is doing rather than what they're working on: the app in front.
    case activity
    /// Their content, such as what they copied. Never persisted, never shown in the inspector, and never
    /// acted on while private details are hidden.
    case content

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What was copied, as the clipboard observer saw it after its filters. Password managers, copies marked
/// concealed and text that looks like a secret never get this far.
public struct ClipboardSignal: Hashable, Sendable {
    public var text: String
    /// Bundle identifier and name of the app in front when the copy happened.
    public var sourceApp: String?
    public var sourceName: String?
    /// Set when the text is a path to something that exists on this Mac (checked by the observer).
    public var existingPath: String?
    public init(text: String, sourceApp: String? = nil, sourceName: String? = nil, existingPath: String? = nil) {
        self.text = text; self.sourceApp = sourceApp; self.sourceName = sourceName; self.existingPath = existingPath
    }
}

public enum ContextSignal: Hashable, Sendable {
    case frontmostApp(bundleID: String?, name: String?)
    case clipboard(ClipboardSignal)

    public var source: ContextSource {
        switch self {
        case .frontmostApp: .frontmostApp
        case .clipboard: .clipboard
        }
    }
    public var privacy: PrivacyClass {
        switch self {
        case .frontmostApp: .activity
        case .clipboard: .content
        }
    }
}

public struct ContextEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let signal: ContextSignal
    public let timestamp: Date
    public init(_ signal: ContextSignal, at timestamp: Date, id: UUID = UUID()) {
        self.signal = signal; self.timestamp = timestamp; self.id = id
    }
    public var source: ContextSource { signal.source }
    public var privacy: PrivacyClass { signal.privacy }

    /// A description safe for the Context Inspector. Content is reduced to its length and origin.
    public var redactedSummary: String {
        switch signal {
        case .frontmostApp(let bundleID, let name):
            return "\(name ?? bundleID ?? "No app") in front"
        case .clipboard(let clip):
            let origin = clip.sourceName.map { " in \($0)" } ?? ""
            return "Copied \(clip.text.count) characters\(origin)"
        }
    }
}

/// Decides, per source, whether an event goes on to the intent engine. A repeat of what last passed
/// within the source's window is a duplicate. An event inside the source's minimum interval is held,
/// and only the latest held event is released once the interval ends, so a burst settles on where it
/// ended. Fingerprints are in-memory hashes and never outlive the process.
public struct ContextGate: Sendable {
    public struct Rule: Equatable, Sendable {
        /// How long a repeat of the last event counts as a duplicate. `.infinity` passes changes only.
        public var repeatWindow: TimeInterval
        /// The shortest gap between two events that both pass.
        public var minimumInterval: TimeInterval
        public init(repeatWindow: TimeInterval, minimumInterval: TimeInterval) {
            self.repeatWindow = repeatWindow; self.minimumInterval = minimumInterval
        }
    }
    public enum Verdict: Equatable, Sendable {
        case pass
        case duplicate
        /// Held: call `flush` at this time to release the latest held event.
        case deferred(until: Date)
    }

    public static let defaultRules: [ContextSource: Rule] = [
        // Switching apps quickly (⌘-Tab through several) settles on the one you stop at.
        .frontmostApp: Rule(repeatWindow: .infinity, minimumInterval: 0.25),
        // Copying the same thing twice in a row is one copy.
        .clipboard: Rule(repeatWindow: 3, minimumInterval: 0.4),
    ]

    private let rules: [ContextSource: Rule]
    private var passed: [ContextSource: (fingerprint: Int, at: Date)] = [:]
    private var held: [ContextSource: ContextEvent] = [:]

    public init(rules: [ContextSource: Rule] = ContextGate.defaultRules) { self.rules = rules }

    public mutating func admit(_ event: ContextEvent) -> Verdict {
        let rule = rule(for: event.source)
        let fingerprint = event.signal.hashValue
        if let last = passed[event.source] {
            let gap = event.timestamp.timeIntervalSince(last.at)
            if last.fingerprint == fingerprint, gap < rule.repeatWindow {
                // Back to what last passed (A → B → A within the interval): nothing changed after all.
                held[event.source] = nil
                return .duplicate
            }
            if gap < rule.minimumInterval {
                held[event.source] = event
                return .deferred(until: last.at.addingTimeInterval(rule.minimumInterval))
            }
        }
        held[event.source] = nil
        passed[event.source] = (fingerprint, event.timestamp)
        return .pass
    }

    /// The latest held event for a source once its interval is over, or nil if there's none, it isn't
    /// time yet, or it turned out to repeat what last passed.
    public mutating func flush(_ source: ContextSource, now: Date) -> ContextEvent? {
        guard let event = held[source] else { return nil }
        let rule = rule(for: source)
        if let last = passed[source], now.timeIntervalSince(last.at) < rule.minimumInterval { return nil }
        held[source] = nil
        let fingerprint = event.signal.hashValue
        if let last = passed[source], last.fingerprint == fingerprint, now.timeIntervalSince(last.at) < rule.repeatWindow { return nil }
        passed[source] = (fingerprint, now)
        return event
    }

    /// Forgets a source, so its next event passes. Used when its observer stops.
    public mutating func reset(_ source: ContextSource) {
        passed[source] = nil; held[source] = nil
    }

    public func hasHeld(_ source: ContextSource) -> Bool { held[source] != nil }

    private func rule(for source: ContextSource) -> Rule {
        rules[source] ?? Rule(repeatWindow: 0, minimumInterval: 0)
    }
}
