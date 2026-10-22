import XCTest
@testable import NotchCore

final class AgentRescueTests: XCTestCase {
    // 2031-03-01 12:00:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_930_132_800)

    func failure(_ category: ActivityCategory = .ci, title: String = "Tests", summary: String? = "3 tests failed in CheckoutTests",
                 url: String? = "https://github.com/argahv/notchflow/actions/runs/42", sensitive: Bool? = nil,
                 agent: AgentMetadata? = nil) -> ActivityEvent {
        ActivityEvent(source: "github", activityId: "42", state: .failed, title: title, category: category, summary: summary,
                      timestamp: t0, actionURL: url, project: "argahv/notchflow", branch: "main", agent: agent, sensitive: sensitive)
    }

    func testAFailedRunBecomesABriefWithEverythingAnAgentNeedsAndNothingMore() {
        XCTAssertEqual(AgentRescue.brief(for: failure()), """
        ## CI run failed: Tests

        - Where: argahv/notchflow, branch `main`
        - Reported by: GitHub Actions
        - When: 2031-03-01T12:00:00Z
        - Run: https://github.com/argahv/notchflow/actions/runs/42
        - Details: 3 tests failed in CheckoutTests

        Please find out why this failed and propose a fix. Show me the change before applying it,
        don't push, and don't change CI, deployment or credentials without asking.
        """)
    }

    func testOnlyFailuresOfWorkAnAgentCanFixAreOffered() {
        XCTAssertTrue(AgentRescue.canHandOff(failure(.build)))
        XCTAssertTrue(AgentRescue.canHandOff(failure(.deploy)))
        XCTAssertFalse(AgentRescue.canHandOff(failure(.download)), "A failed download isn't a code problem")
        XCTAssertFalse(AgentRescue.canHandOff(failure(.meeting)))
        let passed = ActivityEvent(source: "github", activityId: "1", state: .completed, title: "Tests", category: .ci)
        XCTAssertNil(AgentRescue.brief(for: passed))
    }

    func testPrivateOrSecretLookingDetailsAreLeftOut() {
        let secret = AgentRescue.brief(for: failure(summary: "token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234")) ?? ""
        XCTAssertFalse(secret.contains("ghp_"))
        XCTAssertTrue(secret.contains("- Details: left out, they looked like a key or password"))
        let hidden = AgentRescue.brief(for: failure(summary: "customer email in fixture", sensitive: true)) ?? ""
        XCTAssertFalse(hidden.contains("customer"))
        XCTAssertTrue(hidden.contains("marked private"))
    }

    func testAnAgentsOwnFailureNamesTheAgentAndOnlyWebLinksAreIncluded() {
        let agent = AgentMetadata(provider: "Claude Code", sessionId: "s1", repository: "atlas-web")
        var event = failure(.agent, title: "Turn ended with an error", summary: nil, url: "file:///Users/someone/build.log", agent: agent)
        event.project = nil
        let brief = AgentRescue.brief(for: event) ?? ""
        XCTAssertTrue(brief.hasPrefix("## Agent turn failed: Turn ended with an error"))
        XCTAssertTrue(brief.contains("- Where: atlas-web, branch `main`"))
        XCTAssertTrue(brief.contains("- Reported by: Claude Code"))
        XCTAssertFalse(brief.contains("file://"), "A local path isn't put in the brief")
        XCTAssertFalse(brief.contains("- Details:"))
    }
}
