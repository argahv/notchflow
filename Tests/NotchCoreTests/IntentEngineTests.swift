import XCTest
@testable import NotchCore

final class IntentEngineTests: XCTestCase {
    // 2031-03-01 12:00:00 UTC.
    let t0 = Date(timeIntervalSince1970: 1_930_132_800)
    var utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()
    lazy var situation = IntentSituation(calendar: utc)

    func copy(_ text: String, app: String? = "com.apple.dt.Xcode", name: String? = "Xcode", path: String? = nil,
              _ seconds: TimeInterval = 0) -> ContextEvent {
        ContextEvent(.clipboard(ClipboardSignal(text: text, sourceApp: app, sourceName: name, existingPath: path)), at: t0.addingTimeInterval(seconds))
    }
    func suggestion(_ decision: IntentDecision, file: StaticString = #filePath, line: UInt = #line) -> Suggestion? {
        guard case .suggest(let suggestion) = decision else { XCTFail("Held: \(decision)", file: file, line: line); return nil }
        return suggestion
    }
    func reason(_ decision: IntentDecision) -> HoldReason? {
        if case .hold(let reason, _, _) = decision { return reason }
        return nil
    }

    func testACopiedLinkOffersToOpenOrKeepItAndSaysWhy() throws {
        var engine = IntentEngine()
        let link = try XCTUnwrap(suggestion(engine.evaluate(copy("https://github.com/argahv/notchflow"), in: situation)))
        XCTAssertEqual(link.rule, "clipboard.link")
        XCTAssertEqual(link.actions, [.openURL(URL(string: "https://github.com/argahv/notchflow")!), .keepOnShelf("https://github.com/argahv/notchflow"),
                                      .keepAndAct("https://github.com/argahv/notchflow", then: .qrCode)])
        XCTAssertEqual(link.reason, "You copied a web link in Xcode.")
        XCTAssertEqual(link.detail, "github.com/argahv/notchflow · Xcode")
        XCTAssertEqual(link.score, 0.7, accuracy: 0.0001)
        XCTAssertEqual(link.expires, t0.addingTimeInterval(45))
    }

    func testALinkCopiedInABrowserIsOnlyWorthSuggestingWhenItHasTrackers() throws {
        var engine = IntentEngine()
        let plain = engine.evaluate(copy("https://example.com/page", app: "com.apple.Safari", name: "Safari"), in: situation)
        guard case .belowThreshold = reason(plain) else { return XCTFail("Should be held: \(plain)") }
        let tracked = try XCTUnwrap(suggestion(engine.evaluate(copy("https://example.com/page?utm_source=mail", app: "com.apple.Safari", name: "Safari", 30),
                                                               in: situation)))
        XCTAssertEqual(tracked.actions.first, .copyText("https://example.com/page", label: "Copy Clean Link"))
        XCTAssertFalse(tracked.actions.contains(.openURL(URL(string: "https://example.com/page?utm_source=mail")!)), "Already open in the browser")
        XCTAssertEqual(tracked.title, "Link with 1 tracker")
    }

    func testAColorOffersItsOtherNotationsAndCarriesASwatch() throws {
        var engine = IntentEngine()
        let color = try XCTUnwrap(suggestion(engine.evaluate(copy("#0A84FF"), in: situation)))
        XCTAssertEqual(color.actions, [.copyText("rgb(10, 132, 255)", label: "Copy as RGB"), .copyText("hsl(210, 100%, 52%)", label: "Copy as HSL")])
        XCTAssertEqual(color.swatch?.hex, "#0A84FF")
    }

    func testJSONOffersOnlyTheFormatItIsntAlreadyIn() throws {
        var engine = IntentEngine()
        let compact = try XCTUnwrap(suggestion(engine.evaluate(copy(#"{"a":1}"#), in: situation)))
        XCTAssertEqual(compact.actions, [.copyText("{\n  \"a\": 1\n}", label: "Copy Formatted")])
        XCTAssertEqual(compact.detail, "1 key · 7 characters")
    }

    func testCodeAndShortTextAreNeverSuggestedBecauseTheyreCopiedConstantly() {
        var engine = IntentEngine()
        XCTAssertEqual(reason(engine.evaluate(copy("let x = 1;\nlet y = 2;"), in: situation)), .nothingToOffer)
        XCTAssertEqual(reason(engine.evaluate(copy("ok thanks"), in: situation)), .nothingToOffer)
    }

    func testPastDatesAreIgnoredAndDatesThisWeekScoreHigher() throws {
        var engine = IntentEngine()
        let soon = try XCTUnwrap(suggestion(engine.evaluate(copy("March 3, 2031 at 3:30 PM"), in: situation)))
        guard case .remind(let title, _) = soon.actions.first else { return XCTFail("Expected a reminder") }
        XCTAssertEqual(title, "March 3, 2031 at 3:30 PM")
        XCTAssertTrue(soon.components.contains(ScoreComponent("Within the next week", 0.1)))
        XCTAssertEqual(reason(engine.evaluate(copy("March 3, 2030 at 3:30 PM", 60), in: situation)), .nothingToOffer)
    }

    func testAPathIsOnlySuggestedWhenItExistsAndNotWhileInFinder() throws {
        var engine = IntentEngine()
        XCTAssertEqual(reason(engine.evaluate(copy("/no/such/file"), in: situation)), .nothingToOffer)
        let path = try XCTUnwrap(suggestion(engine.evaluate(copy("/Applications", path: "/Applications", 1), in: situation)))
        XCTAssertEqual(path.actions, [.reveal(path: "/Applications"), .openFile(path: "/Applications")])
        let inFinder = engine.evaluate(copy("/Library", app: "com.apple.finder", name: "Finder", path: "/Library", 60), in: situation)
        guard case .belowThreshold = reason(inFinder) else { return XCTFail("Should be held: \(inFinder)") }
    }

    func testNothingIsSuggestedWhileDetailsAreHiddenQuietOrDuringQuietHours() {
        var engine = IntentEngine()
        var hidden = situation; hidden.privateMode = true
        XCTAssertEqual(reason(engine.evaluate(copy("#FFFFFF"), in: hidden)), .detailsHidden)
        var quiet = situation; quiet.quiet = true
        XCTAssertEqual(reason(engine.evaluate(copy("#FFFFFF"), in: quiet)), .quiet)
        var night = situation; night.quietHours = QuietHours(start: 11, end: 13)
        XCTAssertEqual(reason(engine.evaluate(copy("#FFFFFF"), in: night)), .quietHours)
        var off = situation; off.enabled = false
        XCTAssertEqual(reason(engine.evaluate(copy("#FFFFFF"), in: off)), .predictionsOff)
        var noColors = situation; noColors.disabledCategories = [.colors]
        XCTAssertEqual(reason(engine.evaluate(copy("#FFFFFF"), in: noColors)), .categoryOff(.colors))
    }

    func testQuietHoursWrapPastMidnight() {
        let hours = QuietHours(start: 22, end: 8)
        func at(_ hour: Int) -> Date { utc.date(bySettingHour: hour, minute: 0, second: 0, of: t0)! }
        XCTAssertTrue(hours.contains(at(23), calendar: utc))
        XCTAssertTrue(hours.contains(at(3), calendar: utc))
        XCTAssertFalse(hours.contains(at(8), calendar: utc))
        XCTAssertFalse(hours.contains(at(12), calendar: utc))
        XCTAssertFalse(QuietHours(start: 9, end: 9).contains(at(9), calendar: utc), "Equal hours mean never")
    }

    func testTheSameContentIsSuggestedOnceAndARuleWaitsBeforeSuggestingAgain() {
        var engine = IntentEngine()
        XCTAssertNotNil(suggestion(engine.evaluate(copy("https://a.example/x"), in: situation)))
        guard case .coolingDown = reason(engine.evaluate(copy("https://b.example/y", 5), in: situation)) else { return XCTFail("Should cool down") }
        XCTAssertEqual(reason(engine.evaluate(copy("https://a.example/x", 30), in: situation)), .alreadySuggested)
        XCTAssertNotNil(suggestion(engine.evaluate(copy("https://b.example/y", 31), in: situation)))
        XCTAssertNotNil(suggestion(engine.evaluate(copy("#000000", 32), in: situation)), "Other rules aren't affected")
    }

    func testDismissingBacksOffExponentiallyAndFiveInARowMutesTheRule() throws {
        var engine = IntentEngine()
        let first = try XCTUnwrap(suggestion(engine.evaluate(copy("#111111"), in: situation)))
        engine.resolve(first, .dismissed, at: t0)
        guard case .coolingDown(let until) = reason(engine.evaluate(copy("#222222", 60), in: situation)) else { return XCTFail("Should cool down") }
        XCTAssertEqual(until, t0.addingTimeInterval(120))
        XCTAssertNotNil(suggestion(engine.evaluate(copy("#333333", 121), in: situation)))
        var learning = IntentLearning()
        for minute in 0..<4 { learning.record(.dismissed, rule: "clipboard.color", at: t0.addingTimeInterval(Double(minute))) }
        XCTAssertEqual(learning.backoff(for: "clipboard.color"), 960, "2, 4, 8, then 16 minutes")
        learning.record(.dismissed, rule: "clipboard.color", at: t0)
        XCTAssertTrue(learning.isMuted("clipboard.color"))
        engine.learning = learning
        XCTAssertEqual(reason(engine.evaluate(copy("#444444", 7200), in: situation)), .muted)
        engine.learning.unmute("clipboard.color")
        XCTAssertEqual(engine.learning.stats("clipboard.color").dismissed, 0, "Unmuting forgets the dismissals")
        XCTAssertNotNil(suggestion(engine.evaluate(copy("#555555", 7300), in: situation)))
    }

    func testAcceptingRaisesARulesScoreAndDismissingLowersItWithinBounds() {
        var learning = IntentLearning()
        XCTAssertEqual(learning.adjustment(for: "r"), 0)
        for _ in 0..<20 { learning.record(.accepted, rule: "r", at: t0) }
        XCTAssertEqual(learning.adjustment(for: "r"), 0.2, accuracy: 0.0001, "Capped at +0.2")
        for _ in 0..<60 { learning.record(.dismissed, rule: "d", at: t0) }
        XCTAssertEqual(learning.adjustment(for: "d"), -0.3, accuracy: 0.0001, "Capped at −0.3")
        learning.record(.ignored, rule: "i", at: t0)
        learning.record(.ignored, rule: "i", at: t0)
        learning.record(.ignored, rule: "i", at: t0)
        XCTAssertEqual(learning.adjustment(for: "i"), -0.4 / 3, accuracy: 0.0001, "Three ignores weigh as one dismissal")
        XCTAssertEqual(learning.stats("i").consecutiveDismissals, 0, "Ignoring never backs off")
        learning.record(.superseded, rule: "s", at: t0)
        XCTAssertNil(learning.rules["s"], "Being replaced by an alert teaches nothing")
        learning.reset()
        XCTAssertTrue(learning.rules.isEmpty)
    }

    func testLearningStoresRuleCountsAndNeverContent() throws {
        var engine = IntentEngine()
        let link = try XCTUnwrap(suggestion(engine.evaluate(copy("https://private.example/secret-path"), in: situation)))
        engine.resolve(link, .accepted, at: t0)
        let json = String(decoding: try JSONEncoder().encode(engine.learning), as: UTF8.self)
        XCTAssertTrue(json.contains("clipboard.link"))
        XCTAssertFalse(json.contains("private.example"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertEqual(try JSONDecoder().decode(IntentLearning.self, from: Data(json.utf8)), engine.learning)
    }

    func testEachRecentPromptLowersTheNextScoreSoBalancedLimitsItself() {
        var engine = IntentEngine()
        engine.ruleRepeat = 0
        var shownCount = 0
        for index in 0..<6 {
            guard case .suggest(let shown) = engine.evaluate(copy(String(format: "#%06X", index), Double(index)), in: situation) else { break }
            if index == 1 { XCTAssertTrue(shown.components.contains(ScoreComponent("1 shown in the last hour", -0.05))) }
            engine.presented(shown, at: t0.addingTimeInterval(Double(index)))
            shownCount += 1
        }
        XCTAssertEqual(shownCount, 4, "0.75 for a color, less 0.05 per prompt this hour, against Balanced's 0.6")
    }

    func testTheHourlyLimitHoldsEverythingElseUntilTheHourHasPassed() {
        var engine = IntentEngine()
        engine.ruleRepeat = 0
        var more = situation; more.sensitivity = .more
        for index in 0..<6 {
            guard let shown = suggestion(engine.evaluate(copy(String(format: "#%06X", index), Double(index)), in: more)) else { return }
            engine.presented(shown, at: t0.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(reason(engine.evaluate(copy("#ABCDEF", 10), in: more)), .hourlyLimit)
        XCTAssertNotNil(suggestion(engine.evaluate(copy("#ABCDEF", 3700), in: more)), "An hour later the limit has passed")
    }

    func testResettingForgetsLearningAndRecentPromptsAlike() {
        var engine = IntentEngine()
        engine.ruleRepeat = 0
        var more = situation; more.sensitivity = .more
        var shown: [Suggestion] = []
        for index in 0..<6 {
            guard let next = suggestion(engine.evaluate(copy(String(format: "#%06X", index), Double(index)), in: more)) else { return }
            engine.presented(next, at: t0.addingTimeInterval(Double(index)))
            shown.append(next)
        }
        for next in shown { engine.resolve(next, .dismissed, at: t0.addingTimeInterval(6)) }
        XCTAssertTrue(engine.learning.isMuted("clipboard.color"))
        engine.reset()
        XCTAssertTrue(engine.learning.rules.isEmpty)
        let fresh = suggestion(engine.evaluate(copy("#000000", 10), in: situation))
        XCTAssertEqual(fresh?.score ?? 0, 0.75, accuracy: 0.0001, "No penalty for earlier prompts, and the same color can be suggested again")
    }

    func testSensitivityDecidesWhichSuggestionsClearTheBar() {
        var engine = IntentEngine()
        var fewer = situation; fewer.sensitivity = .fewer
        guard case .belowThreshold = reason(engine.evaluate(copy("hello@example.com"), in: fewer)) else { return XCTFail("Fewer holds it") }
        XCTAssertNotNil(suggestion(engine.evaluate(copy("hello@example.com", 1000), in: situation)))
        let passage = Array(repeating: "word", count: 45).joined(separator: " ")
        guard case .belowThreshold = reason(engine.evaluate(copy(passage, 2000), in: situation)) else { return XCTFail("Balanced holds long text") }
        var more = situation; more.sensitivity = .more
        XCTAssertNotNil(suggestion(engine.evaluate(copy(passage + " more", 3000), in: more)))
    }

    func testTheAppInFrontNeverProducesASuggestionByItself() {
        var engine = IntentEngine()
        XCTAssertEqual(reason(engine.evaluate(ContextEvent(.frontmostApp(bundleID: "com.apple.Safari", name: "Safari"), at: t0), in: situation)), .nothingToOffer)
    }
}
