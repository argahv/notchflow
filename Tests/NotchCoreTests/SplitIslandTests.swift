import XCTest
@testable import NotchCore

final class SplitIslandTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func candidate(_ id: String, _ tier: HoverTier, _ family: HoverFamily, ago: TimeInterval = 0) -> HoverCandidate {
        HoverCandidate(id: id, tier: tier, family: family, updated: now.addingTimeInterval(-ago))
    }

    func testAPinnedItemStaysBesideTheLead() {
        let build = candidate("build", .running, .pipeline), agent = candidate("agent", .running, .agent, ago: 5)
        let music = candidate("music", .music, .music), timer = candidate("timer", .imminent, .timer)
        // Unpinned, a running timer outranks the build, so it leads and the build sits beside it.
        let free = HoverPolicy.choose([build, agent, music, timer], current: nil, situation: .init())
        XCTAssertEqual(free.primary?.id, "timer"); XCTAssertEqual(free.secondary?.id, "build")
        let pinned = HoverPolicy.choose([build, agent, music, timer], current: nil, situation: .init(pinned: "music"))
        XCTAssertEqual(pinned.primary?.id, "build"); XCTAssertEqual(pinned.secondary?.id, "music", "keep music visible while working")
    }

    func testAPinYieldsToRequestsAndFailuresAndLapsesWhenItsItemEnds() {
        let input = candidate("claude", .input, .agent), build = candidate("build", .running, .pipeline)
        let failed = candidate("ci", .failure, .pipeline)
        let choice = HoverPolicy.choose([input, build, failed], current: nil, situation: .init(pinned: "build"))
        XCTAssertEqual(choice.primary?.id, "claude", "a request keeps the surface")
        XCTAssertNotEqual(choice.secondary?.id, "build", "two work items never share the island")
        let gone = HoverPolicy.choose([build], current: nil, situation: .init(pinned: "music"))
        XCTAssertEqual(gone.primary?.id, "build"); XCTAssertNil(gone.secondary, "a pin whose item ended changes nothing")
        let calm = HoverPolicy.choose([candidate("dl", .general, .download), build], current: nil, situation: .init(pinned: "dl"))
        XCTAssertEqual(calm.primary?.id, "dl", "with nothing critical, the pinned item can lead")
    }

    func testCyclingStaysWithinTheSameKindAndKeepsThePairing() {
        let a = candidate("a", .running, .agent), b = candidate("b", .running, .pipeline, ago: 1)
        let c = candidate("c", .general, .download, ago: 2), music = candidate("music", .music, .music)
        let all = [a, b, c, music]
        let start = HoverPolicy.choose(all, current: nil, situation: .init())
        XCTAssertEqual(start.primary?.id, "a"); XCTAssertEqual(start.secondary?.id, "music")
        XCTAssertEqual(HoverPolicy.alternatives(all, current: start, side: .primary), 1,
                       "only b also pairs with music; a download doesn't")
        let next = HoverPolicy.cycle(all, current: start, side: .primary, step: 1)
        XCTAssertEqual(next.primary?.id, "b"); XCTAssertEqual(next.secondary?.id, "music")
        XCTAssertEqual(HoverPolicy.cycle(all, current: next, side: .primary, step: 1).primary?.id, "a", "wraps around")
        XCTAssertEqual(HoverPolicy.cycle(all, current: start, side: .primary, step: -1).primary?.id, "b")
        XCTAssertEqual(HoverPolicy.cycle(all, current: start, side: .secondary, step: 1), start, "nowhere else to go")
    }

    func testSingleItemCyclingVisitsEveryLiveWorkItem() {
        let a = candidate("a", .failure, .pipeline), b = candidate("b", .running, .agent), c = candidate("c", .general, .download)
        let start = HoverChoice(primary: a, secondary: nil, others: 2)
        let visited = (1...3).map { HoverPolicy.cycle([a, b, c], current: start, side: .primary, step: $0).primary?.id }
        XCTAssertEqual(visited, ["b", "c", "a"])
        XCTAssertEqual(HoverPolicy.cycle([a, b, c], current: start, side: .primary, step: 1).others, 2)
    }
}
