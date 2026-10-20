import Foundation

/// GitHub Actions workflow runs (REST `GET /repos/{owner}/{repo}/actions/runs`), mapped to activity
/// events. Only fields GitHub documents; no job logs, no write access.
public struct GitHubRun: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String?
    public var displayTitle: String?
    public var headBranch: String?
    public var status: String?
    public var conclusion: String?
    public var htmlUrl: String
    public var runNumber: Int?
    public var event: String?
    public var updatedAt: Date
    public var runStartedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case displayTitle = "display_title", headBranch = "head_branch", htmlUrl = "html_url"
        case runNumber = "run_number", updatedAt = "updated_at", runStartedAt = "run_started_at"
    }
}

public struct GitHubRunsPage: Codable, Sendable {
    public var workflowRuns: [GitHubRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

public enum GitHubRuns {
    public static let source = "github-actions"

    public static func decode(_ data: Data) throws -> [GitHubRun] {
        try ActivityEvent.decoder().decode(GitHubRunsPage.self, from: data).workflowRuns
    }

    /// `owner/name`, as GitHub allows them.
    public static func isRepository(_ value: String) -> Bool { ActivityEvent.isRepository(value) }

    /// Documented `status` and `conclusion` values to a lifecycle. Unknown values stay `unknown`
    /// rather than guessing.
    public static func state(status: String?, conclusion: String?) -> ActivityState {
        switch status {
        case "queued", "requested", "pending": return .queued
        case "in_progress": return .running
        case "waiting": return .waiting           // an environment's protection rules await a reviewer
        case "completed":
            switch conclusion {
            case "success", "neutral": return .completed
            case "failure", "timed_out", "startup_failure": return .failed
            case "cancelled", "skipped", "stale": return .cancelled
            case "action_required": return .waiting
            default: return .unknown
            }
        default: return .unknown
        }
    }

    /// The event for one run, or nil when it's too old for the stack or not worth showing.
    /// `refreshedAt` extends a live run's expiry on every poll, so polling that stops lets it lapse.
    public static func event(for run: GitHubRun, repository: String, refreshedAt now: Date, liveFor: TimeInterval) -> ActivityEvent? {
        let state = state(status: run.status, conclusion: run.conclusion)
        guard state != .unknown, run.updatedAt > now.addingTimeInterval(-6 * 86_400) else { return nil }
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        let title = String((run.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Workflow run \(run.runNumber ?? 0)").prefix(160))
        var event = ActivityEvent(source: source, activityId: String(run.id), state: state, title: title, category: .ci,
                                  summary: run.displayTitle.map { String($0.prefix(2000)) },
                                  timestamp: min(run.updatedAt, now.addingTimeInterval(60)),
                                  actionURL: run.htmlUrl.hasPrefix("https://github.com/") ? run.htmlUrl : nil,
                                  expiresAt: state.terminal ? nil : max(now, run.updatedAt).addingTimeInterval(liveFor),
                                  project: String(name.prefix(80)),
                                  branch: run.headBranch.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
                                  groupKey: String(repository.prefix(128)))
        if event.summary?.isEmpty == true { event.summary = nil }
        return event
    }
}

/// When to poll next. Pure, so the cadence and rate-limit handling are tested without a network.
public struct GitHubPolicy: Equatable, Sendable {
    public var authenticated: Bool
    public var repositories: Int
    public var lowPower: Bool
    public init(authenticated: Bool, repositories: Int, lowPower: Bool) {
        self.authenticated = authenticated; self.repositories = max(1, repositories); self.lowPower = lowPower
    }

    /// Seconds between polls of one repository. Unauthenticated requests share 60 an hour per IP
    /// address, so their interval grows with the number of repositories.
    public func interval(active: Bool) -> TimeInterval {
        var seconds: TimeInterval = authenticated ? (active ? 15 : 60) : (active ? 60 : 180)
        if !authenticated { seconds = max(seconds, Double(repositories) * 60) }
        return lowPower ? seconds * 2 : seconds
    }

    /// Backoff after consecutive failures: doubles from the normal interval, at most 15 minutes.
    public func backoff(failures: Int, active: Bool) -> TimeInterval {
        min(900, interval(active: active) * pow(2, Double(min(failures, 6))))
    }

    /// Honors `Retry-After`, then an exhausted `x-ratelimit-remaining` until `x-ratelimit-reset`.
    public static func rateLimitDelay(status: Int, headers: [String: String], now: Date) -> TimeInterval? {
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let retry = lower["retry-after"].flatMap(TimeInterval.init), retry >= 0 { return min(3600, retry + 1) }
        if lower["x-ratelimit-remaining"] == "0", let reset = lower["x-ratelimit-reset"].flatMap(TimeInterval.init) {
            return min(3600, max(5, Date(timeIntervalSince1970: reset).timeIntervalSince(now) + 5))
        }
        if status == 429 || (status == 403 && lower["x-ratelimit-remaining"] == "0") { return 60 }
        return nil
    }
}
