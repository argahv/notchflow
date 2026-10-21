import Foundation

// Agent Heartbeat and Mission Complete: what the resting notch shows about agents, and which finished
// work earns a moment. Both only use what the providers' events actually report.

/// What the band shows for agents. Each has its own shape, so none relies on colour alone.
public enum AgentPulse: String, Codable, Sendable, CaseIterable {
    /// A session is open and nothing is happening: still.
    case idle
    /// A prompt is being worked on: a slow flow.
    case working
    /// A tool just started: one short directional move.
    case tool
    /// Tests are running (the bridge recognised a test command): a stepped rhythm.
    case tests
    /// The agent is waiting for the person: amber, a raised hand.
    case waiting
    /// A turn just finished: a brief settle, then still.
    case completed
    /// A turn just failed: a restrained red mark.
    case failed
    /// The session ended or went silent: neutral, no motion.
    case disconnected

    /// Whether this pulse moves at all. Movement is also time-limited by the view.
    public var moves: Bool { [.working, .tool, .tests, .completed].contains(self) }
}

public enum AgentPulseRules {
    /// A session reporting nothing for this long is treated as gone quiet, not as still working.
    public static let staleAfter: TimeInterval = 600
    /// How long a finished or failed turn keeps its mark before the band goes still.
    public static let afterglow: TimeInterval = 8

    /// One session's pulse from its latest record.
    public static func pulse(for record: ActivityRecord, now: Date) -> AgentPulse? {
        let event = record.event
        guard let agent = event.agent else { return nil }
        let age = now.timeIntervalSince(event.timestamp)
        switch event.lifecycle {
        case .needsInput, .waiting:
            return .waiting
        case .completed:
            return age <= afterglow ? .completed : nil
        case .failed:
            return age <= afterglow ? .failed : nil
        case .cancelled:
            return age <= afterglow ? .disconnected : nil
        case .running, .starting, .queued, .paused, .unknown:
            if age > staleAfter { return .disconnected }
            switch agent.state {
            case .executingTool?: return agent.tool == "Tests" ? .tests : .tool
            case .working?: return .working
            case .disconnected?: return .disconnected
            case .waitingForUser?, .awaitingAuthorization?: return .waiting
            case .idle?, .starting?, .unknown?, nil: return .idle
            case .completed?: return .completed
            case .failed?: return .failed
            }
        }
    }

    /// The band's one pulse across every session, most important first: someone waiting, a failure,
    /// tests, a tool, work, a finish, idle, gone quiet. Deterministic for any order of records.
    public static func pulse(for records: [ActivityRecord], now: Date) -> AgentPulse? {
        let order: [AgentPulse] = [.waiting, .failed, .tests, .tool, .working, .completed, .idle, .disconnected]
        let pulses = Set(records.compactMap { pulse(for: $0, now: now) })
        return order.first(where: pulses.contains)
    }
}

/// Finished work that may earn a moment.
public struct Completion: Equatable, Sendable {
    public enum Source: String, Sendable { case agent, ci, build, deploy, download, timer, other }
    public var id: String
    public var source: Source
    public var title: String
    /// How long the work actually ran, when it was observed from start to finish.
    public var elapsed: TimeInterval?
    /// Bytes, for downloads.
    public var size: Int64?
    public var at: Date
    public init(id: String, source: Source, title: String, elapsed: TimeInterval? = nil, size: Int64? = nil, at: Date) {
        self.id = id; self.source = source; self.title = title; self.elapsed = elapsed; self.size = size; self.at = at
    }
}

/// Decides how finished work is told: a short celebration in the notch, an ordinary glance, or only a
/// light on the rim. Never over typing, never over someone using the notch, never in quiet mode.
public struct CompletionPolicy: Sendable {
    public enum Importance: Equatable, Sendable { case celebrate, glance, indicate }
    public struct Situation: Equatable, Sendable {
        public var quiet: Bool
        /// A key was pressed in the last moment (time since the last key event, not what was typed).
        public var typing: Bool
        /// The notch is open or the pointer is on it.
        public var busy: Bool
        public init(quiet: Bool = false, typing: Bool = false, busy: Bool = false) {
            self.quiet = quiet; self.typing = typing; self.busy = busy
        }
    }

    /// An agent turn shorter than this is a quick reply, not a mission.
    public var agentMinimum: TimeInterval = 120
    /// A download at least this large is worth a moment.
    public var largeDownload: Int64 = 100 * 1024 * 1024
    /// Completions this close together are told as one.
    public var batchWindow: TimeInterval = 8
    public init() {}

    public func importance(of completion: Completion, in situation: Situation) -> Importance {
        if situation.quiet { return .indicate }
        let meaningful: Bool = switch completion.source {
        case .ci, .build, .deploy, .timer: true
        case .agent: (completion.elapsed ?? 0) >= agentMinimum
        case .download: (completion.size ?? 0) >= largeDownload
        case .other: false
        }
        guard meaningful else { return .glance }
        // A moment that would land on the person's typing or hand waits as a plain glance instead.
        return situation.typing || situation.busy ? .glance : .celebrate
    }

    /// Whether a completion joins one being shown, instead of queueing a second moment.
    public func joins(_ completion: Completion, shownSince: Date) -> Bool {
        completion.at.timeIntervalSince(shownSince) <= batchWindow
    }

    /// "Build succeeded", or "3 tasks finished" with their names, for a batch.
    public static func headline(_ batch: [Completion]) -> (title: String, detail: String) {
        guard let first = batch.first else { return ("Done", "") }
        if batch.count == 1 { return (first.title, "") }
        let names = batch.prefix(3).map(\.title).joined(separator: ", ")
        return ("\(batch.count) tasks finished", batch.count > 3 ? names + ", and more" : names)
    }
}
