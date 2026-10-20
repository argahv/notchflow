import XCTest
@testable import NotchCore

final class GitHubRunsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Shape of `GET /repos/{owner}/{repo}/actions/runs` (fields NotchFlow reads, plus ones it ignores).
    func fixture(status: String, conclusion: String?, updated: Date) -> Data {
        let iso = ISO8601DateFormatter().string(from: updated)
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"total_count": 1, "workflow_runs": [{
          "id": 9876543210, "name": "CI", "display_title": "Fix the stack layout", "head_branch": "main",
          "head_sha": "abc", "status": "\(status)", "conclusion": \(conclusionJSON),
          "html_url": "https://github.com/argahv/notchflow/actions/runs/9876543210", "run_number": 42,
          "event": "push", "created_at": "\(iso)", "updated_at": "\(iso)", "run_started_at": "\(iso)",
          "actor": {"login": "someone"}, "repository": {"full_name": "argahv/notchflow"}
        }]}
        """.utf8)
    }

    func testDecodesDocumentedFieldsAndIgnoresTheRest() throws {
        let runs = try GitHubRuns.decode(fixture(status: "in_progress", conclusion: nil, updated: now))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].id, 9876543210)
        XCTAssertEqual(runs[0].headBranch, "main")
        XCTAssertEqual(runs[0].updatedAt, now)
    }

    func testStatusAndConclusionMapping() {
        let cases: [(String?, String?, ActivityState)] = [
            ("queued", nil, .queued), ("requested", nil, .queued), ("pending", nil, .queued),
            ("in_progress", nil, .running), ("waiting", nil, .waiting),
            ("completed", "success", .completed), ("completed", "neutral", .completed),
            ("completed", "failure", .failed), ("completed", "timed_out", .failed), ("completed", "startup_failure", .failed),
            ("completed", "cancelled", .cancelled), ("completed", "skipped", .cancelled), ("completed", "stale", .cancelled),
            ("completed", "action_required", .waiting), ("completed", "brand_new", .unknown), ("mystery", nil, .unknown), (nil, nil, .unknown)
        ]
        for (status, conclusion, expected) in cases {
            XCTAssertEqual(GitHubRuns.state(status: status, conclusion: conclusion), expected, "\(status ?? "nil")/\(conclusion ?? "nil")")
        }
    }

    func testEventsAreValidAndHonest() throws {
        let running = try GitHubRuns.decode(fixture(status: "in_progress", conclusion: nil, updated: now.addingTimeInterval(-120)))[0]
        let event = try XCTUnwrap(GitHubRuns.event(for: running, repository: "argahv/notchflow", refreshedAt: now, liveFor: 600))
        XCTAssertNoThrow(try event.validate(now: now))
        XCTAssertEqual(event.key, "github-actions:9876543210")
        XCTAssertEqual(event.lifecycle, .running)
        XCTAssertNil(event.progress, "GitHub reports no completion fraction, so none is shown")
        XCTAssertEqual(event.project, "notchflow")
        XCTAssertEqual(event.branch, "main")
        XCTAssertEqual(event.groupKey, "argahv/notchflow")
        XCTAssertEqual(event.expiresAt, now.addingTimeInterval(600), "a live run lapses if polling stops")

        let failed = try GitHubRuns.decode(fixture(status: "completed", conclusion: "failure", updated: now))[0]
        let done = try XCTUnwrap(GitHubRuns.event(for: failed, repository: "argahv/notchflow", refreshedAt: now, liveFor: 600))
        XCTAssertEqual(done.lifecycle, .failed)
        XCTAssertNil(done.expiresAt)
        XCTAssertEqual(done.actionURL, "https://github.com/argahv/notchflow/actions/runs/9876543210")
        XCTAssertNoThrow(try done.validate(now: now))

        let old = try GitHubRuns.decode(fixture(status: "completed", conclusion: "success", updated: now.addingTimeInterval(-8 * 86_400)))[0]
        XCTAssertNil(GitHubRuns.event(for: old, repository: "argahv/notchflow", refreshedAt: now, liveFor: 600), "too old for the contract")
        var foreign = failed; foreign.htmlUrl = "https://evil.example/run"
        XCTAssertNil(GitHubRuns.event(for: foreign, repository: "a/b", refreshedAt: now, liveFor: 600)?.actionURL, "only github.com links open")
    }

    func testRefreshingALiveRunIsNotNews() throws {
        let run = try GitHubRuns.decode(fixture(status: "in_progress", conclusion: nil, updated: now))[0]
        let first = try XCTUnwrap(GitHubRuns.event(for: run, repository: "a/b", refreshedAt: now, liveFor: 600))
        let refreshed = try XCTUnwrap(GitHubRuns.event(for: run, repository: "a/b", refreshedAt: now + 60, liveFor: 600))
        XCTAssertFalse(refreshed.isMaterialChange(from: first))
        var queue = ActivityQueue()
        try queue.ingest(first, now: now); try queue.ingest(refreshed, now: now + 60)
        XCTAssertEqual(queue.records.first?.event.expiresAt, now + 660, "same-instant refresh extends the expiry")
    }

    func testCadenceRespectsTheUnauthenticatedBudget() {
        XCTAssertEqual(GitHubPolicy(authenticated: true, repositories: 3, lowPower: false).interval(active: true), 15)
        XCTAssertEqual(GitHubPolicy(authenticated: true, repositories: 3, lowPower: false).interval(active: false), 60)
        XCTAssertEqual(GitHubPolicy(authenticated: false, repositories: 1, lowPower: false).interval(active: true), 60)
        XCTAssertEqual(GitHubPolicy(authenticated: false, repositories: 4, lowPower: false).interval(active: true), 240,
                       "four repositories × one request a minute stays within 60 an hour")
        XCTAssertEqual(GitHubPolicy(authenticated: false, repositories: 1, lowPower: true).interval(active: false), 360)
        XCTAssertEqual(GitHubPolicy(authenticated: true, repositories: 1, lowPower: false).backoff(failures: 10, active: false), 900)
    }

    func testRateLimitHeaders() {
        XCTAssertEqual(GitHubPolicy.rateLimitDelay(status: 403, headers: ["Retry-After": "30"], now: now), 31)
        let reset = String(Int(now.timeIntervalSince1970) + 120)
        XCTAssertEqual(GitHubPolicy.rateLimitDelay(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset], now: now), 125)
        XCTAssertEqual(GitHubPolicy.rateLimitDelay(status: 429, headers: [:], now: now), 60)
        XCTAssertNil(GitHubPolicy.rateLimitDelay(status: 200, headers: ["x-ratelimit-remaining": "59"], now: now))
        XCTAssertNil(GitHubPolicy.rateLimitDelay(status: 403, headers: [:], now: now), "a plain 403 is a permission error, not a rate limit")
    }
}
