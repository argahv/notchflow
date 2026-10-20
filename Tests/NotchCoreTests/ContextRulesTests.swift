import XCTest
@testable import NotchCore

final class ContextRulesTests: XCTestCase {
    func testFrontmostAppBoostsRelevantWork() {
        XCTAssertEqual(ContextRules.boost(forFrontmost: "com.mitchellh.ghostty"), [.agent, .build, .ci, .deploy])
        XCTAssertEqual(ContextRules.boost(forFrontmost: "com.jetbrains.intellij"), [.agent, .build, .ci, .deploy])
        XCTAssertEqual(ContextRules.boost(forFrontmost: "com.apple.Safari"), [.download, .ci])
        XCTAssertEqual(ContextRules.boost(forFrontmost: "us.zoom.xos"), [.meeting])
        XCTAssertEqual(ContextRules.boost(forFrontmost: "com.apple.Music"), [])
        XCTAssertEqual(ContextRules.boost(forFrontmost: nil), [])
    }

    func testBoostReordersButNeverPromotesPastUrgentWork() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ id: String, _ state: ActivityState, _ category: ActivityCategory) -> ActivityRecord {
            ActivityRecord(event: ActivityEvent(source: "s", activityId: id, state: state, title: id, category: category, timestamp: now))
        }
        let records = [record("download", .running, .download), record("build", .running, .build), record("approve", .needsInput, .agent)]
        let editor = ActivityRanking.rank(records, context: RankingContext(now: now, boosted: ContextRules.boost(forFrontmost: "com.apple.dt.Xcode")))
        XCTAssertEqual(editor.map(\.id), ["s:approve", "s:build", "s:download"])
        let browser = ActivityRanking.rank(records, context: RankingContext(now: now, boosted: ContextRules.boost(forFrontmost: "com.apple.Safari")))
        XCTAssertEqual(browser.map(\.id), ["s:approve", "s:download", "s:build"], "a request for input still leads")
    }

    func testModesAreDistinctPresetsAndCustomIsDetected() {
        let all = ProductMode.allCases.map(\.settings)
        XCTAssertEqual(Set(all.map { "\($0)" }).count, all.count, "every mode sets something different")
        for mode in ProductMode.allCases { XCTAssertEqual(ProductMode.matching(mode.settings), mode) }
        var custom = ProductMode.dynamic.settings
        custom.showBattery = false
        XCTAssertNil(ProductMode.matching(custom), "a changed setting is a custom setup, not silently a mode")
    }
}
