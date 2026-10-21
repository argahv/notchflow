import XCTest
@testable import NotchCore

final class TimelineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func entry(_ id: String, _ minutesAgo: Double, _ kind: TimelineEntry.Kind = .task) -> TimelineEntry {
        TimelineEntry(id: id, date: now.addingTimeInterval(-minutesAgo * 60), kind: kind, title: id, detail: "")
    }

    func testEntriesFromEverySourceAreMergedNewestFirstAndOnce() {
        let activities = [entry("build", 30, .pipeline), entry("agent", 5, .agent)]
        let shelf = [entry("report.pdf", 12, .shelf), entry("agent", 5, .agent)]
        let merged = TimelineRules.merge([activities, shelf], since: nil)
        XCTAssertEqual(merged.map(\.id), ["agent", "report.pdf", "build"])
    }

    func testRetentionAndTheLimitAreHonoured() {
        let old = entry("old", 60 * 24 * 40), recent = entry("recent", 1)
        XCTAssertEqual(TimelineRules.merge([[old, recent]], since: now.addingTimeInterval(-30 * 86_400)).map(\.id), ["recent"])
        let many = (0..<100).map { entry("e\($0)", Double($0)) }
        XCTAssertEqual(TimelineRules.merge([many], since: nil).count, TimelineRules.limit)
        XCTAssertEqual(TimelineRules.merge([many], since: nil).first?.id, "e0")
    }

    func testTheCursorMovesThroughTimeWithoutRunningOff() {
        var cursor = TimelineCursor(count: 3)
        XCTAssertTrue(cursor.atPresent)
        cursor.move(-1); XCTAssertEqual(cursor.index, 0, "nothing newer than now")
        cursor.move(1); cursor.move(1); cursor.move(1); XCTAssertEqual(cursor.index, 2); XCTAssertTrue(cursor.atOldest)
        cursor.reset(count: 2); XCTAssertEqual(cursor.index, 1, "an entry that went away moves the cursor back in range")
        var empty = TimelineCursor(count: 0); empty.move(1); XCTAssertEqual(empty.index, 0)
    }
}
