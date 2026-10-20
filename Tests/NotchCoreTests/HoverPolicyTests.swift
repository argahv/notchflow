import XCTest
@testable import NotchCore

final class HoverPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func c(_ id: String, _ tier: HoverTier, _ family: HoverFamily, ago: TimeInterval = 0) -> HoverCandidate {
        HoverCandidate(id: id, tier: tier, family: family, updated: now - ago)
    }
    func choose(_ list: [HoverCandidate], _ current: HoverChoice? = nil, hovered: Bool = false, locked: Bool = false, split: Bool = true) -> HoverChoice {
        HoverPolicy.choose(list, current: current, situation: .init(hovered: hovered, locked: locked, allowSplit: split))
    }

    func testNothingActiveFallsBackToQuickAccess() {
        XCTAssertEqual(choose([]), .quickAccess)
    }

    func testTiersFollowTheBriefsOrder() {
        let all = [c("music", .music, .music), c("build", .running, .pipeline), c("fail", .failure, .pipeline),
                   c("input", .input, .agent), c("timer", .imminent, .timer), c("dl", .general, .download)]
        XCTAssertEqual(choose(all, split: false).primary?.id, "input")
        XCTAssertEqual(choose(all.filter { $0.id != "input" }, split: false).primary?.id, "fail")
        XCTAssertEqual(choose([c("music", .music, .music), c("dl", .general, .download)], split: false).primary?.id, "music")
    }

    func testEqualsDontReshuffleOnBackgroundUpdates() {
        let first = choose([c("a", .running, .agent, ago: 10)])
        let next = choose([c("a", .running, .agent, ago: 10), c("b", .running, .pipeline, ago: 0)], first)
        XCTAssertEqual(next.primary?.id, "a", "a newer equal doesn't take over")
        XCTAssertEqual(next.others, 1)
        XCTAssertEqual(choose([c("a", .running, .agent, ago: 10), c("b", .failure, .pipeline)], first).primary?.id, "b",
                       "something more important does")
    }

    func testWhileHoveredOnlyCriticalArrivalsReplaceThePreview() {
        let shown = choose([c("music", .music, .music)])
        let running = choose([c("music", .music, .music), c("build", .running, .pipeline)], shown, hovered: true, split: false)
        XCTAssertEqual(running.primary?.id, "music", "a running build doesn't yank the preview from under the pointer")
        let input = choose([c("music", .music, .music), c("input", .input, .agent)], shown, hovered: true, split: false)
        XCTAssertEqual(input.primary?.id, "input", "input needed is critical")
    }

    func testAControlInUseLocksTheSelection() {
        let shown = choose([c("music", .music, .music)])
        XCTAssertEqual(choose([c("music", .music, .music), c("fail", .failure, .pipeline)], shown, locked: true, split: false).primary?.id, "music")
    }

    func testAnItemThatDisappearsIsReplaced() {
        let shown = choose([c("timer", .imminent, .timer), c("build", .running, .pipeline)], split: false)
        XCTAssertEqual(shown.primary?.id, "timer")
        XCTAssertEqual(choose([c("build", .running, .pipeline)], shown, hovered: true, locked: true).primary?.id, "build",
                       "even while hovered or locked, a finished timer can't stay on screen")
    }

    func testSplitPairsAmbientWithWorkThatMatters() {
        let musicAndInput = choose([c("music", .music, .music), c("input", .input, .agent)])
        XCTAssertEqual(musicAndInput.primary?.id, "input")
        XCTAssertEqual(musicAndInput.secondary?.id, "music")
        let timerAndBuild = choose([c("timer", .imminent, .timer), c("build", .running, .pipeline)])
        XCTAssertEqual(timerAndBuild.primary?.id, "timer")
        XCTAssertEqual(timerAndBuild.secondary?.id, "build")
        XCTAssertNil(choose([c("music", .music, .music), c("dl", .general, .download)]).secondary, "a download doesn't earn a split")
        let twoAgents = choose([c("a", .input, .agent), c("b", .input, .agent, ago: 5)])
        XCTAssertNil(twoAgents.secondary, "two activities summarise as a count, not a split")
        XCTAssertEqual(twoAgents.others, 1)
        XCTAssertNil(choose([c("music", .music, .music), c("input", .input, .agent)], split: false).secondary, "narrow displays stay single")
    }

    func testCountExcludesWhatsShownAndAmbientItems() {
        let choice = choose([c("input", .input, .agent), c("music", .music, .music), c("build", .running, .pipeline), c("dl", .general, .download)])
        XCTAssertEqual(choice.primary?.id, "input")
        XCTAssertEqual(choice.secondary?.id, "music")
        XCTAssertEqual(choice.others, 2)
    }
}
