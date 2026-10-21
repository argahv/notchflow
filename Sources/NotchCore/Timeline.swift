import Foundation

/// Time Travel: a short visual history built only from what NotchFlow already keeps (finished activities,
/// shelf items, the latest screenshot, and clipboard text when that feature is on). Nothing is stored for
/// it; it's assembled when opened and follows each source's own retention.
public struct TimelineEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case agent, pipeline, download, timer, task, shelf, clipboard, screenshot }
    public var id: String
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String
    public init(id: String, date: Date, kind: Kind, title: String, detail: String) {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.detail = detail
    }
}

public enum TimelineRules {
    public static let limit = 80

    /// Newest first, one entry per id, nothing before the retention cutoff, at most `limit`.
    public static func merge(_ groups: [[TimelineEntry]], since cutoff: Date?, limit: Int = limit) -> [TimelineEntry] {
        var seen = Set<String>()
        return groups.joined()
            .filter { entry in cutoff.map { entry.date >= $0 } ?? true }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit).map { $0 }
    }
}

/// Where Time Travel is looking: 0 is the present, higher is further back. Never runs off either end.
public struct TimelineCursor: Equatable, Sendable {
    public private(set) var index = 0
    public private(set) var count: Int
    public init(count: Int) { self.count = max(0, count) }
    public var atPresent: Bool { index == 0 }
    public var atOldest: Bool { index >= count - 1 }
    public mutating func move(_ step: Int) { index = min(max(0, index + step), max(0, count - 1)) }
    public mutating func reset(count: Int) { self.count = max(0, count); index = min(index, max(0, self.count - 1)) }
}
