import XCTest
@testable import NotchCore

final class AttentionCenterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let idle = AttentionContext()
    func item(_ id: String, _ priority: AttentionPriority, _ offset: TimeInterval = 0) -> AttentionItem {
        AttentionItem(id: id, priority: priority, arrived: now.addingTimeInterval(offset))
    }

    func testPhaseMapsToPriority() {
        XCTAssertEqual(AttentionPriority(phase: .failed), .critical)
        XCTAssertEqual(AttentionPriority(phase: .waiting), .actionRequired)
        XCTAssertEqual(AttentionPriority(phase: .completed), .informational)
        XCTAssertEqual(AttentionPriority(phase: .progress), .background)
        XCTAssertEqual(AttentionPriority(phase: .cancelled), .silent)
        XCTAssertFalse(AttentionPriority.background.interrupts)
    }

    func testCriticalPreemptsAndEqualOrLowerWaits() {
        var center = AttentionCenter()
        XCTAssertEqual(center.receive(item("build", .informational), context: idle), .present(item("build", .informational)))
        XCTAssertEqual(center.receive(item("deploy", .critical, 1), context: idle), .present(item("deploy", .critical, 1)))
        XCTAssertEqual(center.receive(item("review", .actionRequired, 2), context: idle), .queue)
        XCTAssertEqual(center.current?.id, "deploy")
        XCTAssertEqual(Set(center.pending.map(\.id)), ["build", "review"])
    }

    func testSameTaskRefreshesInsteadOfStacking() {
        var center = AttentionCenter()
        _ = center.receive(item("agent", .actionRequired), context: idle)
        XCTAssertEqual(center.receive(item("agent", .critical, 1), context: idle), .present(item("agent", .critical, 1)))
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.receive(item("agent", .background, 2), context: idle), .ignore)
        XCTAssertNil(center.current)
    }

    func testThrottleHoldsBurstsThenReplays() {
        var center = AttentionCenter(minimumInterval: 3)
        _ = center.receive(item("a", .informational), context: idle)
        _ = center.dismissCurrent(now: now.addingTimeInterval(0.5), context: idle)
        XCTAssertEqual(center.receive(item("b", .actionRequired, 1), context: idle), .queue)
        XCTAssertNil(center.resume(now: now.addingTimeInterval(2), context: idle))
        XCTAssertEqual(center.resume(now: now.addingTimeInterval(3.5), context: idle)?.id, "b")
    }

    func testEditingOnlyIndicatesAndReplaysWhatStillMatters() {
        var center = AttentionCenter()
        let editing = AttentionContext(editing: true, expanded: true)
        XCTAssertEqual(center.receive(item("done", .informational), context: editing), .indicate)
        XCTAssertEqual(center.receive(item("failed", .critical, 1), context: editing), .indicate)
        XCTAssertNil(center.current, "nothing may open over a note being edited")
        XCTAssertNil(center.resume(now: now.addingTimeInterval(5), context: editing))
        XCTAssertEqual(center.resume(now: now.addingTimeInterval(40), context: idle)?.id, "failed")
        XCTAssertFalse(center.pending.contains { $0.id == "done" }, "stale informational items are dropped")
    }

    func testSuppressedNeverQueues() {
        var center = AttentionCenter()
        XCTAssertEqual(center.receive(item("x", .critical), context: AttentionContext(suppressed: true)), .indicate)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testCapacityDropsLeastImportant() {
        var center = AttentionCenter(capacity: 2)
        _ = center.receive(item("showing", .critical), context: idle)
        _ = center.receive(item("low", .informational, 1), context: idle)
        _ = center.receive(item("mid", .actionRequired, 2), context: idle)
        _ = center.receive(item("high", .critical, 3), context: AttentionContext(expanded: true))
        XCTAssertEqual(Set(center.pending.map(\.id)), ["mid", "high"])
    }
}

final class SurfaceGeometryTests: XCTestCase {
    let display = DisplayGeometry(x: 0, y: 0, width: 1710, height: 1112, notchWidth: 208, notchHeight: 37.5)

    func testContentHeightSitsBelowTheBandAndSnapsToWholePoints() {
        let size = SurfaceGeometryEngine.resolve(.content(width: 460, height: 120.2), display: display, wing: 110)
        XCTAssertEqual(size, SurfaceSize(width: 460, height: 158))
    }

    func testWidthKeepsRoomForBandControlsAndStaysOnScreen() {
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 200, height: 40), display: display, wing: 110).width, 428)
        let narrow = DisplayGeometry(x: 0, y: 0, width: 400, height: 600, notchWidth: 190, notchHeight: 30)
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 40), display: narrow, wing: 110).width, 368)
    }

    func testEmptyContentStaysCompactAndTallContentIsCapped() {
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 0, minHeight: 64), display: display, wing: 110).height, 102)
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 2000, maxHeight: 420), display: display, wing: 110).height, 458)
        let short = DisplayGeometry(x: 0, y: 0, width: 1440, height: 400, notchWidth: 180, notchHeight: 32)
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 2000, maxHeight: 900), display: short, wing: 110).height, 330)
    }

    func testSubPointJitterKeepsThePreviousSize() {
        let previous = SurfaceSize(width: 460, height: 200)
        XCTAssertEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 163), display: display, wing: 110, previous: previous), previous)
        XCTAssertNotEqual(SurfaceGeometryEngine.resolve(.content(width: 460, height: 170), display: display, wing: 110, previous: previous), previous)
    }
}

final class InteractionContractTests: XCTestCase {
    func testAwarenessFollowsPointerAndDragWithDragWinning() {
        var state = InteractionState()
        state.send(.approach); XCTAssertEqual(state.awareness, .pointer)
        state.send(.dragApproach); state.send(.approach); XCTAssertEqual(state.awareness, .drag)
        state.send(.beginDrag); state.send(.retreat)
        XCTAssertEqual(state.awareness, .drag, "an active drag keeps the target ready")
        state.send(.endDrag); XCTAssertEqual(state.awareness, .drag, "leaving the target keeps it ready while the drag is near")
        state.send(.retreat); XCTAssertEqual(state.awareness, .none)
        state.send(.approach); state.send(.dismiss); XCTAssertEqual(state.awareness, .none)
    }

    func testContradictoryEventsResolveDeterministically() {
        var state = InteractionState()
        state.send(.enter); state.send(.dismiss); state.send(.leave)
        XCTAssertEqual(state.presentation, .collapsed)
        state.send(.togglePin); state.send(.attention); state.send(.leave)
        XCTAssertEqual(state.presentation, .expanded, "a pinned workspace ignores attention and leave")
        state.send(.beginDrag); state.send(.dismiss)
        XCTAssertFalse(state.pinned || state.dragging || state.editing)
        XCTAssertEqual(state.presentation, .collapsed)
        state.send(.attention); state.send(.enter); XCTAssertEqual(state.presentation, .preview)
        state.send(.beginEditing); state.send(.attention); state.send(.leave)
        XCTAssertEqual(state.presentation, .expanded, "background attention never collapses an editor")
    }
}

final class HistoryRetentionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func testPruneKeepsWorkInProgressAndRemovesOldFinishedRecords() throws {
        var queue = ActivityQueue()
        try queue.ingest(ActivityEvent(source: "ci", activityId: "old", phase: .completed, title: "Old", timestamp: now.addingTimeInterval(-90_000)), now: now)
        try queue.ingest(ActivityEvent(source: "ci", activityId: "live", phase: .progress, title: "Live", timestamp: now.addingTimeInterval(-90_000)), now: now)
        try queue.ingest(ActivityEvent(source: "ci", activityId: "new", phase: .failed, title: "New", timestamp: now), now: now)
        queue.prune(before: now.addingTimeInterval(-86_400))
        XCTAssertEqual(Set(queue.records.map(\.event.activityId)), ["live", "new"])
        queue.remove("ci:new"); XCTAssertEqual(queue.records.map(\.event.activityId), ["live"])
        queue.clear(); XCTAssertTrue(queue.records.isEmpty)
    }
}
