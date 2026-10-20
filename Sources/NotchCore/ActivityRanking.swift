import Foundation

extension AttentionPriority {
    /// v2 priority from the lifecycle state, so an idle or running agent never interrupts.
    public init(state: ActivityState) {
        switch state {
        case .failed: self = .critical
        case .needsInput, .waiting: self = .actionRequired
        case .completed: self = .informational
        case .queued, .starting, .running, .paused, .unknown: self = .background
        case .cancelled: self = .silent
        }
    }
}

extension ActivityRecord {
    /// A request that can still be answered: present, unexpired, and the task still needs input.
    public func actionableRequest(now: Date = Date()) -> ActivityRequest? {
        guard let request = event.request, event.lifecycle == .needsInput, request.expiresAt > now else { return nil }
        return request
    }
}

/// What the ranking may know about the person's situation.
public struct RankingContext: Sendable {
    public var now: Date
    /// Categories related to the frontmost application (e.g. agents while a terminal is active).
    public var boosted: Set<ActivityCategory>
    public init(now: Date = Date(), boosted: Set<ActivityCategory> = []) { self.now = now; self.boosted = boosted }
}

/// Deterministic priority for the task stack, the band and the glance:
/// critical failures → actionable agent requests → other requests for input → failed builds and
/// deployments → running work related to the current context → passive progress → recent completions.
/// Pinned items lead within their tier; recency breaks ties.
public enum ActivityRanking {
    public static func score(_ record: ActivityRecord, context: RankingContext) -> Int {
        let event = record.event
        let pipeline: Set<ActivityCategory> = [.ci, .build, .deploy, .download]
        let boosted = context.boosted.contains(event.kind)
        var score: Int
        switch event.lifecycle {
        case .failed:
            score = (pipeline.contains(event.kind) ? 600 : 800) + (boosted ? 20 : 0)
        case .needsInput, .waiting:
            score = (record.actionableRequest(now: context.now) != nil ? 760 : 700) + (boosted ? 20 : 0)
        case .running, .starting, .queued, .paused, .unknown:
            // Context matters most here: foreground work outranks passive progress.
            score = boosted ? 500 : 300
        case .completed:
            score = 200 + (boosted ? 20 : 0)
        case .cancelled:
            score = 100
        }
        if record.isPinned { score += 40 }
        return score
    }

    public static func rank(_ records: [ActivityRecord], context: RankingContext) -> [ActivityRecord] {
        records.sorted { lhs, rhs in
            let left = score(lhs, context: context), right = score(rhs, context: context)
            if left != right { return left > right }
            if lhs.event.timestamp != rhs.event.timestamp { return lhs.event.timestamp > rhs.event.timestamp }
            return lhs.id < rhs.id
        }
    }
}
