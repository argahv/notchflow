import Foundation

/// Contract v1 lifecycle, kept for compatibility and as the coarse visibility signal.
public enum ActivityPhase: String, Codable, CaseIterable, Sendable {
    case started, progress, waiting, completed, failed, cancelled
    public var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
    public var priority: Int {
        switch self { case .waiting: return 4; case .failed: return 3
        case .started, .progress: return 2; default: return 1 }
    }
}

/// Contract v2 lifecycle. Separate from presentation: a task can run while its card is hidden.
public enum ActivityState: String, Codable, CaseIterable, Sendable {
    case queued, starting, running, waiting, needsInput, paused, completed, failed, cancelled, unknown
    public var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
    public init(phase: ActivityPhase) {
        switch phase {
        case .started: self = .starting
        case .progress: self = .running
        case .waiting: self = .waiting
        case .completed: self = .completed
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
    /// The v1 phase a v2 state implies, so v1 consumers keep working.
    public var phase: ActivityPhase {
        switch self {
        case .queued, .starting: .started
        case .running, .paused, .unknown: .progress
        case .waiting, .needsInput: .waiting
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

public enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    case task, agent, build, deploy, ci, download, timer, meeting, system
}

/// What an agent session is doing, only as far as its provider's events justify.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case idle, starting, working, executingTool, waitingForUser, awaitingAuthorization, completed, failed, disconnected, unknown
}

public struct AgentMetadata: Codable, Equatable, Sendable {
    public var provider: String
    public var sessionId: String
    public var state: AgentState?
    public var tool: String?
    /// `TERM_PROGRAM` of the session's terminal, used to bring that application forward.
    public var terminal: String?
    /// `owner/name` when the working directory's origin is on GitHub.
    public var repository: String?
    public init(provider: String, sessionId: String, state: AgentState? = nil, tool: String? = nil,
                terminal: String? = nil, repository: String? = nil) {
        self.provider = provider; self.sessionId = sessionId; self.state = state
        self.tool = tool; self.terminal = terminal; self.repository = repository
    }
}

/// A pending request that can be answered from NotchFlow, published by a hook that is waiting for
/// the answer. Lives in memory only; never written to History.
public struct ActivityRequest: Codable, Equatable, Sendable {
    public var id: String
    public var nonce: String
    public var kind: String
    public var tool: String
    public var detail: String?
    public var expiresAt: Date
    public init(id: String, nonce: String, kind: String = "permission", tool: String, detail: String? = nil, expiresAt: Date) {
        self.id = id; self.nonce = nonce; self.kind = kind; self.tool = tool; self.detail = detail; self.expiresAt = expiresAt
    }
}

public struct ActivityEvent: Codable, Equatable, Sendable {
    public var version: Int
    public var source: String
    public var activityId: String
    public var phase: ActivityPhase
    public var title: String
    public var summary: String?
    public var timestamp: Date
    public var progress: Double?
    public var actionURL: String?
    public var expiresAt: Date?
    // v2 (all optional; v1 events and stored history decode unchanged)
    public var category: ActivityCategory?
    public var state: ActivityState?
    public var project: String?
    public var branch: String?
    public var groupKey: String?
    public var parentId: String?
    public var sensitive: Bool?
    public var agent: AgentMetadata?
    public var request: ActivityRequest?

    public var key: String { source + ":" + activityId }
    public var lifecycle: ActivityState { state ?? ActivityState(phase: phase) }
    public var kind: ActivityCategory { category ?? (agent != nil ? .agent : .task) }

    public init(source: String, activityId: String, phase: ActivityPhase, title: String,
                summary: String? = nil, timestamp: Date = Date(), progress: Double? = nil,
                actionURL: String? = nil, expiresAt: Date? = nil) {
        version = 1; self.source = source; self.activityId = activityId; self.phase = phase
        self.title = title; self.summary = summary; self.timestamp = timestamp
        self.progress = progress; self.actionURL = actionURL; self.expiresAt = expiresAt
    }

    /// A v2 event whose v1 phase follows from its state.
    public init(source: String, activityId: String, state: ActivityState, title: String, category: ActivityCategory,
                summary: String? = nil, timestamp: Date = Date(), progress: Double? = nil, actionURL: String? = nil,
                expiresAt: Date? = nil, project: String? = nil, branch: String? = nil, groupKey: String? = nil,
                agent: AgentMetadata? = nil, request: ActivityRequest? = nil, sensitive: Bool? = nil) {
        self.init(source: source, activityId: activityId, phase: state.phase, title: title, summary: summary,
                  timestamp: timestamp, progress: progress, actionURL: actionURL, expiresAt: expiresAt)
        version = 2; self.state = state; self.category = category; self.project = project; self.branch = branch
        self.groupKey = groupKey; self.agent = agent; self.request = request; self.sensitive = sensitive
    }

    public func validate(now: Date = Date()) throws {
        guard version == 1 || version == 2 else { throw EventError.invalid("Unsupported event version") }
        guard !source.isEmpty, source.count <= 64, !activityId.isEmpty, activityId.count <= 128,
              !title.isEmpty, title.count <= 160, (summary?.count ?? 0) <= 2000 else {
            throw EventError.invalid("Invalid event text length")
        }
        guard progress == nil || (progress!.isFinite && (0...1).contains(progress!)) else {
            throw EventError.invalid("Progress must be between zero and one")
        }
        guard timestamp <= now.addingTimeInterval(300), timestamp >= now.addingTimeInterval(-604800) else {
            throw EventError.invalid("Event timestamp outside accepted window")
        }
        if let actionURL {
            guard let url = URL(string: actionURL),
                  ["https", "http", "file", "vscode"].contains(url.scheme?.lowercased() ?? ""),
                  actionURL.count <= 4096 else { throw EventError.invalid("Unsupported action URL") }
            if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host == nil {
                throw EventError.invalid("Web action requires a host")
            }
        }
        if let expiresAt, expiresAt <= timestamp { throw EventError.invalid("Expiry precedes event") }
        let hasV2Fields = category != nil || state != nil || project != nil || branch != nil || groupKey != nil
            || parentId != nil || sensitive != nil || agent != nil || request != nil
        if version == 1 && hasV2Fields { throw EventError.invalid("Version 1 events cannot carry version 2 fields") }
        guard version == 2 else { return }
        if let state, state.terminal != phase.terminal { throw EventError.invalid("State contradicts phase") }
        for (value, limit) in [(project, 80), (branch, 120), (groupKey, 128), (parentId, 128)] {
            if let value, value.isEmpty || value.count > limit { throw EventError.invalid("Invalid event field length") }
        }
        if let agent {
            guard Self.isToken(agent.provider, max: 32), !agent.sessionId.isEmpty, agent.sessionId.count <= 128,
                  (agent.tool?.count ?? 0) <= 64, (agent.terminal?.count ?? 0) <= 64 else {
                throw EventError.invalid("Invalid agent metadata")
            }
            if let repository = agent.repository, !Self.isRepository(repository) { throw EventError.invalid("Invalid repository") }
        }
        if let request {
            guard Self.isHex(request.id, length: 32), Self.isHex(request.nonce, length: 32), request.kind == "permission",
                  !request.tool.isEmpty, request.tool.count <= 64, (request.detail?.count ?? 0) <= 400,
                  request.expiresAt > timestamp, request.expiresAt <= timestamp.addingTimeInterval(600) else {
                throw EventError.invalid("Invalid request")
            }
            guard lifecycle == .needsInput, agent != nil else { throw EventError.invalid("Requests belong to agents that need input") }
        }
    }

    /// Whether an update is news worth attention: a new task, a new state, a new request, or a new
    /// title. Heartbeats, progress ticks, tool-by-tool agent updates, expiry refreshes and a request
    /// being withdrawn change the row quietly.
    public func isMaterialChange(from prior: ActivityEvent?) -> Bool {
        guard let prior else { return true }
        let newRequest = request != nil && prior.request?.id != request?.id
        return prior.lifecycle != lifecycle || newRequest || prior.title != title
    }

    /// The same event without anything that must not reach History on disk.
    public var historySafe: ActivityEvent {
        var copy = self
        copy.request = nil
        if sensitive == true { copy.summary = nil }
        return copy
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    static func isToken(_ value: String, max: Int) -> Bool {
        !value.isEmpty && value.count <= max && value.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) }
    }
    static func isRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isToken(String($0), max: 100) }
    }

    /// ISO 8601 with or without fractional seconds: hook bursts carry milliseconds so events from the
    /// same second still apply in order; v1 publishers and older History use whole seconds.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected an ISO 8601 date"))
        }
        return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
}

public enum EventError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ActivityRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { event.key }
    public var event: ActivityEvent
    public var snoozedUntil: Date?
    public var firstSeen: Date?
    public var pinned: Bool?
    /// Hidden from the task stack; the record stays in History and the task itself is unaffected.
    public var dismissedAt: Date?
    public var isPinned: Bool { pinned == true }
}

public struct ActivityQueue: Codable, Sendable {
    public private(set) var records: [ActivityRecord] = []
    public init() {}

    public mutating func ingest(_ event: ActivityEvent, now: Date = Date()) throws {
        try event.validate(now: now)
        if let index = records.firstIndex(where: { $0.id == event.key }) {
            let current = records[index].event
            guard current.timestamp <= event.timestamp else { return }
            // A finished task never returns to running because a same-instant update arrived late.
            if current.timestamp == event.timestamp, current.lifecycle.terminal, !event.lifecycle.terminal { return }
            if current.lifecycle != event.lifecycle { records[index].dismissedAt = nil }
            records[index].event = event
        } else {
            records.append(ActivityRecord(event: event, firstSeen: now))
        }
        records.sort { $0.event.timestamp > $1.event.timestamp }
        records = Array(records.prefix(200))
    }
    public mutating func snooze(_ id: String, until: Date) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].snoozedUntil = until }
    }
    public mutating func setPinned(_ id: String, _ pinned: Bool) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].pinned = pinned ? true : nil }
    }
    public mutating func dismiss(_ id: String, at date: Date = Date()) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].dismissedAt = date }
    }
    /// Drops an answered or expired request so a stale prompt can't be acted on.
    public mutating func clearRequest(_ id: String) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].event.request = nil }
    }
    public mutating func remove(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func clear() { records.removeAll() }
    /// History retention: drops finished records older than the cutoff; work still in progress stays.
    public mutating func prune(before cutoff: Date) {
        records.removeAll { $0.event.lifecycle.terminal && $0.event.timestamp < cutoff && !$0.isPinned }
    }

    /// How long a failure stays in the stack before it's only in History, unless hidden sooner.
    public static let failureWindow: TimeInterval = 3600

    /// The stack: live work, plus failures from the last hour (they still need a look). Excludes
    /// snoozed, hidden and expired records; pinned records always stay.
    public func visible(now: Date = Date()) -> [ActivityRecord] {
        records.filter { record in
            guard record.dismissedAt == nil, (record.snoozedUntil ?? .distantPast) <= now else { return false }
            if record.isPinned { return true }
            let event = record.event
            if event.lifecycle == .failed { return event.timestamp.addingTimeInterval(Self.failureWindow) > now }
            return !event.lifecycle.terminal && (event.expiresAt ?? event.timestamp.addingTimeInterval(3600)) > now
        }.sorted {
            if $0.event.phase.priority != $1.event.phase.priority {
                return $0.event.phase.priority > $1.event.phase.priority
            }
            return $0.event.timestamp > $1.event.timestamp
        }
    }

    /// A copy safe to write to disk: no pending requests, no sensitive summaries.
    public var historySafe: ActivityQueue {
        var copy = self
        copy.records = records.map { record in var record = record; record.event = record.event.historySafe; return record }
        return copy
    }
}
