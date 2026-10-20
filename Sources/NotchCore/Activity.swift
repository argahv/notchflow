import Foundation

public enum ActivityPhase: String, Codable, CaseIterable, Sendable {
    case started, progress, waiting, completed, failed, cancelled
    public var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
    public var priority: Int {
        switch self { case .waiting: return 4; case .failed: return 3
        case .started, .progress: return 2; default: return 1 }
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
    public var key: String { source + ":" + activityId }

    public init(source: String, activityId: String, phase: ActivityPhase, title: String,
                summary: String? = nil, timestamp: Date = Date(), progress: Double? = nil,
                actionURL: String? = nil, expiresAt: Date? = nil) {
        version = 1; self.source = source; self.activityId = activityId; self.phase = phase
        self.title = title; self.summary = summary; self.timestamp = timestamp
        self.progress = progress; self.actionURL = actionURL; self.expiresAt = expiresAt
    }
    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw EventError.invalid("Unsupported event version") }
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
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
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
}

public struct ActivityQueue: Codable, Sendable {
    public private(set) var records: [ActivityRecord] = []
    public init() {}
    public mutating func ingest(_ event: ActivityEvent, now: Date = Date()) throws {
        try event.validate(now: now)
        if let index = records.firstIndex(where: { $0.id == event.key }) {
            guard records[index].event.timestamp <= event.timestamp else { return }
            records[index].event = event
        } else { records.append(ActivityRecord(event: event)) }
        records.sort { $0.event.timestamp > $1.event.timestamp }
        records = Array(records.prefix(200))
    }
    public mutating func snooze(_ id: String, until: Date) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].snoozedUntil = until }
    }
    public mutating func remove(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func clear() { records.removeAll() }
    /// History retention: drops finished records older than the cutoff; work still in progress stays.
    public mutating func prune(before cutoff: Date) {
        records.removeAll { $0.event.phase.terminal && $0.event.timestamp < cutoff }
    }
    public func visible(now: Date = Date()) -> [ActivityRecord] {
        records.filter {
            !$0.event.phase.terminal && ($0.snoozedUntil ?? .distantPast) <= now &&
            ($0.event.expiresAt ?? $0.event.timestamp.addingTimeInterval(3600)) > now
        }.sorted {
            if $0.event.phase.priority != $1.event.phase.priority {
                return $0.event.phase.priority > $1.event.phase.priority
            }
            return $0.event.timestamp > $1.event.timestamp
        }
    }
}
