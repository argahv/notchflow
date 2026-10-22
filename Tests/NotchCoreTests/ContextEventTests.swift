import XCTest
@testable import NotchCore

final class ContextEventTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    func app(_ id: String, _ seconds: TimeInterval) -> ContextEvent {
        ContextEvent(.frontmostApp(bundleID: id, name: id), at: t0.addingTimeInterval(seconds))
    }
    func copy(_ text: String, _ seconds: TimeInterval) -> ContextEvent {
        ContextEvent(.clipboard(ClipboardSignal(text: text, sourceApp: "com.apple.Safari", sourceName: "Safari")), at: t0.addingTimeInterval(seconds))
    }

    func testRapidAppSwitchingSettlesOnTheAppYouStopAt() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(app("A", 0)), .pass)
        XCTAssertEqual(gate.admit(app("B", 0.1)), .deferred(until: t0.addingTimeInterval(0.25)))
        XCTAssertEqual(gate.admit(app("C", 0.2)), .deferred(until: t0.addingTimeInterval(0.25)))
        XCTAssertNil(gate.flush(.frontmostApp, now: t0.addingTimeInterval(0.2)), "Not before the interval ends")
        XCTAssertEqual(gate.flush(.frontmostApp, now: t0.addingTimeInterval(0.25))?.signal, .frontmostApp(bundleID: "C", name: "C"))
        XCTAssertNil(gate.flush(.frontmostApp, now: t0.addingTimeInterval(0.5)), "Released once")
        XCTAssertEqual(gate.admit(app("B", 1)), .pass)
    }

    func testSwitchingAwayAndBackWithinTheIntervalReportsNothing() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(app("A", 0)), .pass)
        XCTAssertEqual(gate.admit(app("B", 0.1)), .deferred(until: t0.addingTimeInterval(0.25)))
        XCTAssertEqual(gate.admit(app("A", 0.2)), .duplicate)
        XCTAssertNil(gate.flush(.frontmostApp, now: t0.addingTimeInterval(0.3)))
    }

    func testTheSameAppInFrontIsOneEventHoweverMuchTimePasses() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(app("A", 0)), .pass)
        XCTAssertEqual(gate.admit(app("A", 3600)), .duplicate)
    }

    func testCopyingTheSameTextTwiceInARowIsOneCopyButLaterItCountsAgain() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(copy("hello", 0)), .pass)
        XCTAssertEqual(gate.admit(copy("hello", 1)), .duplicate)
        XCTAssertEqual(gate.admit(copy("world", 1.5)), .pass)
        XCTAssertEqual(gate.admit(copy("world", 5)), .pass, "Past the three-second window it's a new copy")
    }

    func testSourcesAreCoalescedIndependently() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(app("A", 0)), .pass)
        XCTAssertEqual(gate.admit(copy("x", 0.05)), .pass)
        XCTAssertEqual(gate.admit(app("B", 0.1)), .deferred(until: t0.addingTimeInterval(0.25)))
        XCTAssertTrue(gate.hasHeld(.frontmostApp))
        XCTAssertFalse(gate.hasHeld(.clipboard))
    }

    func testResettingASourceLetsItsNextEventThrough() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(app("A", 0)), .pass)
        gate.reset(.frontmostApp)
        XCTAssertEqual(gate.admit(app("A", 1)), .pass)
    }

    func testClipboardSignalsAreContentAndTheirSummaryNeverContainsTheText() {
        let event = copy("my secret plan", 0)
        XCTAssertEqual(event.privacy, .content)
        XCTAssertEqual(event.source, .clipboard)
        XCTAssertFalse(event.redactedSummary.contains("secret"))
        XCTAssertEqual(event.redactedSummary, "Copied 14 characters in Safari")
    }

    func testTheAppInFrontIsActivityNotContent() {
        let event = app("com.apple.dt.Xcode", 0)
        XCTAssertEqual(event.privacy, .activity)
        XCTAssertLessThan(event.privacy, .content)
        XCTAssertEqual(event.redactedSummary, "com.apple.dt.Xcode in front")
    }
}

final class ClipEntityTests: XCTestCase {
    func entity(_ text: String) -> ClipEntity { ClipEntityDetector.detect(text).entity }

    func testHexAndRGBColorsAreReadExactlyAndConvertedBothWays() {
        guard case .color(let blue) = entity("#0A84FF") else { return XCTFail("Not a color") }
        XCTAssertEqual(blue.rgb, "rgb(10, 132, 255)")
        XCTAssertEqual(blue.hsl, "hsl(210, 100%, 52%)")
        XCTAssertEqual(blue.notation, .hex)
        XCTAssertEqual(ColorValue(parsing: "#fff")?.hex, "#FFFFFF")
        let red = ColorValue(parsing: "rgb(255, 0, 0)")
        XCTAssertEqual(red?.hex, "#FF0000")
        XCTAssertEqual(red?.hsl, "hsl(0, 100%, 50%)")
        XCTAssertEqual(red?.notation, .rgb)
        let shade = ColorValue(parsing: "rgba(0,0,0,0.5)")
        XCTAssertEqual(shade?.rgb, "rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(shade?.hex, "#00000080")
        XCTAssertNil(ColorValue(parsing: "#12345"))
        XCTAssertNil(ColorValue(parsing: "rgb(300, 0, 0)"))
    }

    func testLinksEmailsAndPathsAreRecognized() {
        XCTAssertEqual(entity("https://github.com/argahv/notchflow"), .link(URL(string: "https://github.com/argahv/notchflow")!))
        XCTAssertEqual(entity(" hello@example.com\n"), .email("hello@example.com"))
        XCTAssertEqual(entity("/Applications/Safari.app"), .filePath("/Applications/Safari.app"))
        XCTAssertEqual(entity("~/Documents/report.pdf"), .filePath("~/Documents/report.pdf"))
        XCTAssertEqual(ClipEntityDetector.detect("https://example.com").confidence, 1)
    }

    func testAddressesPhoneNumbersAndDatesNeedToBeMostOfTheText() {
        guard case .address = entity("1 Infinite Loop, Cupertino, CA 95014") else { return XCTFail("Not an address") }
        guard case .phone = entity("+1 (415) 555-0100") else { return XCTFail("Not a phone number") }
        guard case .date(let date, let hasTime) = entity("March 3, 2031 at 3:30 PM") else { return XCTFail("Not a date") }
        XCTAssertTrue(hasTime)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2031, 3, 3, 15, 30])
        guard case .date(let day, let dayHasTime) = entity("March 3, 2031") else { return XCTFail("Not a date") }
        XCTAssertFalse(dayHasTime)
        XCTAssertEqual(Calendar.current.component(.hour, from: day), 9, "A date without a time is due at 9:00")
        // A sentence that only mentions a date is just text.
        XCTAssertEqual(entity("We could probably talk about the plan for the launch sometime around March 3, 2031 if that suits everyone"), .plain)
    }

    func testCodeLongProseAndShortTextAreToldApart() {
        XCTAssertEqual(entity("func greet() {\n    print(\"hi\");\n}"), .code)
        let paragraph = Array(repeating: "word", count: 50).joined(separator: " ")
        XCTAssertEqual(entity(paragraph), .prose(words: 50))
        XCTAssertEqual(entity("see you soon"), .plain)
        XCTAssertEqual(entity("   "), .plain)
    }

    func testJSONIsReformattedWithoutReorderingOrTouchingStrings() {
        let compact = #"{"b":1,"a":[1,2],"s":"a, {b}: \"c\"","e":{},"f":[]}"#
        XCTAssertEqual(entity(compact), .json)
        let pretty = JSONFormatter.pretty(compact)
        XCTAssertEqual(pretty, """
        {
          "b": 1,
          "a": [
            1,
            2
          ],
          "s": "a, {b}: \\"c\\"",
          "e": {},
          "f": []
        }
        """)
        XCTAssertEqual(JSONFormatter.minified(pretty ?? ""), compact)
        XCTAssertEqual(JSONFormatter.topLevelCount(compact), 5)
        XCTAssertNil(JSONFormatter.pretty("{not json}"))
        XCTAssertFalse(JSONFormatter.isDocument("[]"))
        XCTAssertFalse(JSONFormatter.isDocument("42"))
    }

    func testLinkCleaningRemovesTrackersOnly() {
        let tracked = URL(string: "https://example.com/a?utm_source=x&id=7&fbclid=y#top")!
        XCTAssertEqual(LinkCleaner.clean(tracked)?.absoluteString, "https://example.com/a?id=7#top")
        XCTAssertEqual(LinkCleaner.trackerCount(tracked), 2)
        XCTAssertNil(LinkCleaner.clean(URL(string: "https://example.com/a?id=7")!), "Nothing to remove")
        XCTAssertEqual(LinkCleaner.clean(URL(string: "https://example.com/p?utm_medium=a")!)?.absoluteString, "https://example.com/p")
        XCTAssertEqual(LinkCleaner.clean(URL(string: "https://youtu.be/abc?si=XYZ&t=10")!)?.absoluteString, "https://youtu.be/abc?t=10")
        XCTAssertNil(LinkCleaner.clean(URL(string: "https://example.com/?si=1")!), "si is only a tracker on sharing hosts")
    }
}
