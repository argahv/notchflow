import XCTest
@testable import NotchCore

final class NotchCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func testPinDragAndEditingPreventAccidentalCollapse() {
        var state = InteractionState()
        state.send(.enter); XCTAssertEqual(state.presentation, .preview)
        state.send(.beginEditing); state.send(.leave); XCTAssertEqual(state.presentation, .expanded)
        state.send(.endEditing); state.send(.togglePin); state.send(.leave)
        XCTAssertEqual(state.presentation, .expanded)
        state.send(.togglePin); state.send(.beginDrag); state.send(.leave)
        XCTAssertEqual(state.presentation, .expanded)
        state.send(.endDrag); state.send(.leave); XCTAssertEqual(state.presentation, .collapsed)
    }
    func testAttentionDoesNotReplaceActiveWorkspace() {
        var state = InteractionState(); state.send(.beginEditing); state.send(.attention)
        XCTAssertEqual(state.presentation, .expanded); XCTAssertTrue(state.editing)
        state.send(.dismiss); XCTAssertFalse(state.editing); XCTAssertFalse(state.pinned)
    }
    func testGeometryUsesGlobalDisplayOrigin() {
        let geometry = DisplayGeometry(x: -1920, y: 100, width: 1920, height: 1080)
        let origin = geometry.origin(panelWidth: 540, panelHeight: 480)
        XCTAssertEqual(origin.x, -1230); XCTAssertEqual(origin.y, 700)
    }
    func testCountdownSurvivesSleepAndCompletesOnlyOnce() throws {
        var countdown = Countdown(); countdown.start(seconds: 1500, now: now)
        let restored = try JSONDecoder().decode(Countdown.self, from: JSONEncoder().encode(countdown))
        XCTAssertEqual(restored.remaining(at: now.addingTimeInterval(1200)), 300)
        XCTAssertTrue(countdown.consumeCompletion(now: now.addingTimeInterval(1800)))
        XCTAssertFalse(countdown.consumeCompletion(now: now.addingTimeInterval(1801)))
    }
    func testPausedTimerDoesNotElapse() {
        var countdown = Countdown(); countdown.start(seconds: 60, now: now)
        countdown.pause(now: now.addingTimeInterval(10))
        XCTAssertEqual(countdown.remaining(at: now.addingTimeInterval(600)), 50)
        countdown.resume(now: now.addingTimeInterval(600))
        XCTAssertEqual(countdown.remaining(at: now.addingTimeInterval(610)), 40)
    }
    func testQueueDeduplicatesAndIgnoresOutOfOrderEvents() throws {
        var queue = ActivityQueue()
        var event = ActivityEvent(source: "build", activityId: "one", phase: .started, title: "Build", timestamp: now)
        try queue.ingest(event, now: now)
        event.phase = .completed; event.timestamp = now.addingTimeInterval(1)
        try queue.ingest(event, now: now.addingTimeInterval(1))
        event.phase = .progress; event.timestamp = now.addingTimeInterval(-1)
        try queue.ingest(event, now: now)
        XCTAssertEqual(queue.records.count, 1)
        XCTAssertEqual(queue.records.first?.event.phase, .completed)
        XCTAssertTrue(queue.visible(now: now).isEmpty)
    }
    func testWaitingPrioritizesAndSnoozeExpires() throws {
        var queue = ActivityQueue()
        let waiting = ActivityEvent(source: "agent", activityId: "one", phase: .waiting, title: "Decision", timestamp: now)
        let build = ActivityEvent(source: "build", activityId: "one", phase: .progress, title: "Tests", timestamp: now.addingTimeInterval(1))
        try queue.ingest(waiting, now: now); try queue.ingest(build, now: now.addingTimeInterval(1))
        XCTAssertEqual(queue.visible(now: now).first?.id, waiting.key)
        queue.snooze(waiting.key, until: now.addingTimeInterval(600))
        XCTAssertEqual(queue.visible(now: now).first?.id, build.key)
        XCTAssertEqual(queue.visible(now: now.addingTimeInterval(601)).first?.id, waiting.key)
        XCTAssertTrue(queue.visible(now: now.addingTimeInterval(3602)).isEmpty)
    }
    func testExpiryAndURLValidation() throws {
        var event = ActivityEvent(source: "agent", activityId: "one", phase: .started, title: "Task", timestamp: now, actionURL: "javascript:alert(1)")
        XCTAssertThrowsError(try event.validate(now: now))
        event.actionURL = "https://example.com/logs"; event.progress = 2
        XCTAssertThrowsError(try event.validate(now: now))
        event.progress = 0.5; event.expiresAt = now.addingTimeInterval(-1)
        XCTAssertThrowsError(try event.validate(now: now))
        event.expiresAt = now.addingTimeInterval(30)
        var queue = ActivityQueue(); try queue.ingest(event, now: now)
        XCTAssertTrue(queue.visible(now: now.addingTimeInterval(31)).isEmpty)
    }
    func testEventJSONRoundTrip() throws {
        let event = ActivityEvent(source: "test", activityId: "one", phase: .waiting, title: "Review", timestamp: now)
        let data = try ActivityEvent.encoder().encode(event)
        XCTAssertEqual(try ActivityEvent.decoder().decode(ActivityEvent.self, from: data), event)
    }
}
