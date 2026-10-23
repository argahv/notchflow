import XCTest
@testable import NotchCore

final class TransitionIntervalRegistryTests: XCTestCase {
    func testSupersedingReturnsAndRemovesEveryEarlierOpenInterval() {
        var registry = TransitionIntervalRegistry<String>()
        registry.insert("first", for: 4)
        registry.insert("second", for: 5)
        registry.insert("latest", for: 6)

        let superseded = registry.supersede(before: 6)
        XCTAssertEqual(superseded.map(\.transition), [4, 5])
        XCTAssertEqual(superseded.map(\.reason), [.superseded(by: 6), .superseded(by: 6)])
        XCTAssertNil(registry.end(4, reason: .completed))
        XCTAssertNil(registry.end(5, reason: .fallback))
        XCTAssertEqual(registry.end(6, reason: .completed)?.interval, "latest")
    }

    func testCompletionAndFallbackCanEndAnIntervalOnlyOnce() {
        var registry = TransitionIntervalRegistry<String>()
        registry.insert("interval", for: 12)

        let fallback = registry.end(12, reason: .fallback)
        XCTAssertEqual(fallback?.interval, "interval")
        XCTAssertEqual(fallback?.reason, .fallback)
        XCTAssertNil(registry.end(12, reason: .completed))

        registry.insert("completed", for: 13)
        XCTAssertEqual(registry.end(13, reason: .completed)?.reason, .completed)
        XCTAssertNil(registry.end(13, reason: .fallback))
    }
}
