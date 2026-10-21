import XCTest
@testable import NotchCore

final class AgentPulseTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ id: String, _ lifecycle: ActivityState, _ state: AgentState, tool: String? = nil, ago: TimeInterval = 1) -> ActivityRecord {
        let event = ActivityEvent(source: "claude", activityId: id, state: lifecycle, title: "Claude", category: .agent,
                                  timestamp: now.addingTimeInterval(-ago),
                                  agent: AgentMetadata(provider: "claude", sessionId: id, state: state, tool: tool))
        return ActivityRecord(event: event, firstSeen: now.addingTimeInterval(-ago))
    }

    func testEachReportedStateHasItsOwnPulse() {
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .running, .working), now: now), .working)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .running, .executingTool, tool: "Bash"), now: now), .tool)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .running, .executingTool, tool: "Tests"), now: now), .tests)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .needsInput, .awaitingAuthorization, tool: "Bash"), now: now), .waiting)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .queued, .idle), now: now), .idle)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .completed, .completed), now: now), .completed)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .failed, .failed), now: now), .failed)
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .cancelled, .disconnected), now: now), .disconnected)
    }

    func testFinishesFadeAndSilentSessionsStopMoving() {
        XCTAssertNil(AgentPulseRules.pulse(for: session("a", .completed, .completed, ago: 9), now: now), "the settle is brief")
        XCTAssertEqual(AgentPulseRules.pulse(for: session("a", .running, .working, ago: 601), now: now), .disconnected,
                       "no events for ten minutes: not shown as still working")
        XCTAssertFalse(AgentPulse.disconnected.moves); XCTAssertFalse(AgentPulse.waiting.moves); XCTAssertTrue(AgentPulse.working.moves)
        let event = ActivityEvent(source: "build", activityId: "b", phase: .progress, title: "Build", timestamp: now)
        XCTAssertNil(AgentPulseRules.pulse(for: ActivityRecord(event: event, firstSeen: now), now: now), "only agents pulse")
    }

    func testSeveralSessionsShowTheMostImportantPulseWhateverTheOrder() {
        let records = [session("a", .running, .working), session("b", .needsInput, .waitingForUser),
                       session("c", .running, .executingTool, tool: "Tests")]
        XCTAssertEqual(AgentPulseRules.pulse(for: records, now: now), .waiting)
        XCTAssertEqual(AgentPulseRules.pulse(for: records.reversed(), now: now), .waiting)
        XCTAssertEqual(AgentPulseRules.pulse(for: [records[0], records[2]], now: now), .tests)
        XCTAssertEqual(AgentPulseRules.pulse(for: [session("d", .completed, .completed), records[0]], now: now), .working,
                       "one session finishing doesn't hide another still working")
        XCTAssertNil(AgentPulseRules.pulse(for: [], now: now))
    }

    // MARK: Mission Complete

    func testOnlyMeaningfulFinishesAreCelebrated() {
        let policy = CompletionPolicy()
        let calm = CompletionPolicy.Situation()
        func importance(_ source: Completion.Source, elapsed: TimeInterval? = nil, size: Int64? = nil) -> CompletionPolicy.Importance {
            policy.importance(of: Completion(id: "x", source: source, title: "Done", elapsed: elapsed, size: size, at: now), in: calm)
        }
        XCTAssertEqual(importance(.ci), .celebrate)
        XCTAssertEqual(importance(.deploy), .celebrate)
        XCTAssertEqual(importance(.timer), .celebrate)
        XCTAssertEqual(importance(.agent, elapsed: 30), .glance, "a quick reply isn't a mission")
        XCTAssertEqual(importance(.agent, elapsed: 300), .celebrate)
        XCTAssertEqual(importance(.agent), .glance, "elapsed time not observed: no claim")
        XCTAssertEqual(importance(.download, size: 10_000_000), .glance)
        XCTAssertEqual(importance(.download, size: 200_000_000), .celebrate)
        XCTAssertEqual(importance(.other), .glance)
    }

    func testCelebrationsNeverLandOnTypingOrAnOpenNotch() {
        let policy = CompletionPolicy()
        let build = Completion(id: "b", source: .build, title: "Build succeeded", at: now)
        XCTAssertEqual(policy.importance(of: build, in: .init(quiet: true)), .indicate)
        XCTAssertEqual(policy.importance(of: build, in: .init(typing: true)), .glance)
        XCTAssertEqual(policy.importance(of: build, in: .init(busy: true)), .glance)
    }

    func testFinishesCloseTogetherAreToldAsOne() {
        let policy = CompletionPolicy()
        let shown = now
        XCTAssertTrue(policy.joins(Completion(id: "2", source: .ci, title: "CI", at: now.addingTimeInterval(5)), shownSince: shown))
        XCTAssertFalse(policy.joins(Completion(id: "3", source: .ci, title: "CI", at: now.addingTimeInterval(20)), shownSince: shown))
        let batch = ["Build succeeded", "CI passed", "Claude finished", "Deploy done"].enumerated().map {
            Completion(id: "\($0.offset)", source: .build, title: $0.element, at: now)
        }
        XCTAssertEqual(CompletionPolicy.headline(Array(batch.prefix(1))).title, "Build succeeded")
        XCTAssertEqual(CompletionPolicy.headline(Array(batch.prefix(2))).title, "2 tasks finished")
        XCTAssertEqual(CompletionPolicy.headline(batch).detail, "Build succeeded, CI passed, Claude finished, and more")
    }
}
