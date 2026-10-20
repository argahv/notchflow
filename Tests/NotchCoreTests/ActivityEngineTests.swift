import XCTest
@testable import NotchCore

final class ActivityEngineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let hex = String(repeating: "a1", count: 16)

    func agentEvent(_ state: ActivityState, at offset: TimeInterval = 0, session: String = "s1",
                    request: ActivityRequest? = nil) -> ActivityEvent {
        ActivityEvent(source: "claude-code", activityId: session, state: state, title: "Claude", category: .agent,
                      timestamp: now.addingTimeInterval(offset), project: "portfolio",
                      agent: AgentMetadata(provider: "claude-code", sessionId: session), request: request)
    }

    func testVersionOneEventsAndHistoryStillDecode() throws {
        let json = #"{"version":1,"source":"build","activityId":"one","phase":"progress","title":"Tests","timestamp":"2023-11-14T22:13:20Z"}"#
        let event = try ActivityEvent.decoder().decode(ActivityEvent.self, from: Data(json.utf8))
        XCTAssertNoThrow(try event.validate(now: now))
        XCTAssertEqual(event.lifecycle, .running)
        XCTAssertEqual(event.kind, .task)
        var tagged = event; tagged.category = .ci
        XCTAssertThrowsError(try tagged.validate(now: now), "v1 events cannot carry v2 fields")
    }

    func testStateMustAgreeWithPhaseAndRequestsAreStrict() {
        var event = agentEvent(.running); event.phase = .completed
        XCTAssertThrowsError(try event.validate(now: now))
        let good = ActivityRequest(id: hex, nonce: hex, tool: "Bash", expiresAt: now.addingTimeInterval(30))
        XCTAssertNoThrow(try agentEvent(.needsInput, request: good).validate(now: now))
        var badID = good; badID.id = "XYZ"
        XCTAssertThrowsError(try agentEvent(.needsInput, request: badID).validate(now: now))
        var farExpiry = good; farExpiry.expiresAt = now.addingTimeInterval(3600)
        XCTAssertThrowsError(try agentEvent(.needsInput, request: farExpiry).validate(now: now))
        XCTAssertThrowsError(try agentEvent(.running, request: good).validate(now: now), "only a task needing input carries a request")
        var long = agentEvent(.running); long.project = String(repeating: "p", count: 81)
        XCTAssertThrowsError(try long.validate(now: now))
    }

    func testOutOfOrderAndSameInstantUpdatesNeverResurrectFinishedWork() throws {
        var queue = ActivityQueue()
        try queue.ingest(agentEvent(.running, at: 0), now: now)
        try queue.ingest(agentEvent(.completed, at: 5), now: now)
        try queue.ingest(agentEvent(.running, at: 3), now: now)
        XCTAssertEqual(queue.records.first?.event.lifecycle, .completed, "older event ignored")
        try queue.ingest(agentEvent(.running, at: 5), now: now)
        XCTAssertEqual(queue.records.first?.event.lifecycle, .completed, "same-instant late event ignored")
        try queue.ingest(agentEvent(.running, at: 9), now: now)
        XCTAssertEqual(queue.records.first?.event.lifecycle, .running, "a genuinely newer turn is accepted")
        XCTAssertEqual(queue.records.count, 1)
    }

    func testMillisecondTimestampsDecodeAndRoundTrip() throws {
        let json = #"{"version":2,"source":"codex","activityId":"t","phase":"progress","state":"running","title":"Codex","timestamp":"2026-10-20T10:00:00.250Z"}"#
        let event = try ActivityEvent.decoder().decode(ActivityEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try ActivityEvent.decoder().decode(ActivityEvent.self, from: ActivityEvent.encoder().encode(event)), event)
    }

    func testOnlyMaterialChangesAreNews() {
        let running = agentEvent(.running)
        XCTAssertTrue(running.isMaterialChange(from: nil))
        var heartbeat = running; heartbeat.timestamp += 30; heartbeat.expiresAt = now.addingTimeInterval(900); heartbeat.progress = 0.5
        heartbeat.agent?.state = .executingTool; heartbeat.agent?.tool = "Bash"
        XCTAssertFalse(heartbeat.isMaterialChange(from: running), "heartbeats and tool updates are quiet")
        XCTAssertTrue(agentEvent(.needsInput).isMaterialChange(from: running))
        let request = ActivityRequest(id: String(repeating: "a", count: 32), nonce: String(repeating: "b", count: 32), tool: "Bash", expiresAt: now + 30)
        let asking = agentEvent(.needsInput, request: request)
        XCTAssertTrue(asking.isMaterialChange(from: agentEvent(.needsInput)), "a new request is news")
        XCTAssertFalse(agentEvent(.needsInput).isMaterialChange(from: asking), "a withdrawn request doesn't alert again")
    }

    func testFailuresStayInTheStackForAnHourAndCompletionsLeave() throws {
        var queue = ActivityQueue()
        try queue.ingest(agentEvent(.failed), now: now)
        try queue.ingest(ActivityEvent(source: "build", activityId: "b", state: .completed, title: "Build", category: .build, timestamp: now), now: now)
        XCTAssertEqual(queue.visible(now: now).map(\.id), ["claude-code:s1"])
        XCTAssertTrue(queue.visible(now: now.addingTimeInterval(ActivityQueue.failureWindow + 1)).isEmpty)
        queue.dismiss("claude-code:s1", at: now)
        XCTAssertTrue(queue.visible(now: now).isEmpty, "hiding a failure takes it out of the stack")
        XCTAssertEqual(queue.records.count, 2, "both stay in History")
    }

    func testDismissHidesUntilTheStateChangesAndPinsStayVisible() throws {
        var queue = ActivityQueue()
        try queue.ingest(agentEvent(.running), now: now)
        queue.dismiss("claude-code:s1", at: now)
        XCTAssertTrue(queue.visible(now: now).isEmpty)
        try queue.ingest(agentEvent(.needsInput, at: 2), now: now)
        XCTAssertEqual(queue.visible(now: now).count, 1, "new attention brings it back")
        queue.setPinned("claude-code:s1", true)
        try queue.ingest(agentEvent(.completed, at: 4), now: now)
        XCTAssertEqual(queue.visible(now: now).count, 1, "pinned work stays in the stack when finished")
        queue.prune(before: now.addingTimeInterval(100))
        XCTAssertEqual(queue.records.count, 1, "pinned records survive retention")
    }

    func testHistoryNeverStoresRequestsOrSensitiveSummaries() throws {
        var queue = ActivityQueue()
        let request = ActivityRequest(id: hex, nonce: hex, tool: "Bash", detail: "rm -rf build", expiresAt: now.addingTimeInterval(30))
        var event = agentEvent(.needsInput, request: request); event.summary = "secret"; event.sensitive = true
        try queue.ingest(event, now: now)
        let stored = queue.historySafe.records.first?.event
        XCTAssertNil(stored?.request); XCTAssertNil(stored?.summary)
        XCTAssertNotNil(queue.records.first?.event.request, "the live queue keeps the request")
        queue.clearRequest("claude-code:s1")
        XCTAssertNil(queue.records.first?.event.request)
    }

    func testRankingOrdersTiersDeterministically() throws {
        func record(_ id: String, _ state: ActivityState, _ category: ActivityCategory, _ offset: TimeInterval = 0,
                    request: ActivityRequest? = nil, pinned: Bool = false) -> ActivityRecord {
            var event = ActivityEvent(source: "src", activityId: id, state: state, title: id, category: category,
                                      timestamp: now.addingTimeInterval(offset), request: request)
            if request != nil { event.agent = AgentMetadata(provider: "claude-code", sessionId: id) }
            return ActivityRecord(event: event, pinned: pinned ? true : nil)
        }
        let live = ActivityRequest(id: hex, nonce: hex, tool: "Bash", expiresAt: now.addingTimeInterval(30))
        let stale = ActivityRequest(id: hex, nonce: hex, tool: "Bash", expiresAt: now.addingTimeInterval(-1))
        let records = [
            record("music-ish", .running, .task),
            record("ci-failed", .failed, .ci),
            record("agent-failed", .failed, .agent),
            record("approve", .needsInput, .agent, request: live),
            record("stale", .needsInput, .agent, 1, request: stale),
            record("done", .completed, .build),
            record("build", .running, .build),
        ]
        let order = ActivityRanking.rank(records, context: RankingContext(now: now)).map(\.event.activityId)
        XCTAssertEqual(order, ["agent-failed", "approve", "stale", "ci-failed", "build", "music-ish", "done"])
        let developer = ActivityRanking.rank(records, context: RankingContext(now: now, boosted: [.build]))
        XCTAssertEqual(developer.firstIndex { $0.event.activityId == "build" }, 4, "foreground work leads passive progress")
        let pinned = ActivityRanking.rank([record("a", .running, .task, 5), record("b", .running, .task, 0, pinned: true)],
                                          context: RankingContext(now: now))
        XCTAssertEqual(pinned.first?.event.activityId, "b")
    }

    func testStatePriorityKeepsIdleAgentsQuiet() {
        XCTAssertEqual(AttentionPriority(state: .starting), .background)
        XCTAssertEqual(AttentionPriority(state: .running), .background)
        XCTAssertEqual(AttentionPriority(state: .needsInput), .actionRequired)
        XCTAssertEqual(AttentionPriority(state: .failed), .critical)
        XCTAssertEqual(AttentionPriority(state: .cancelled), .silent)
    }

    func testSourcesWithTheSameIdentifierStaySeparate() throws {
        var queue = ActivityQueue()
        try queue.ingest(ActivityEvent(source: "claude-code", activityId: "x", phase: .progress, title: "A", timestamp: now), now: now)
        try queue.ingest(ActivityEvent(source: "codex", activityId: "x", phase: .progress, title: "B", timestamp: now), now: now)
        XCTAssertEqual(queue.records.count, 2)
    }
}
