import XCTest
@testable import NotchCore

final class WorkModeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_930_132_800)
    let all = Set(ModeDetector.allCases)

    func read(_ app: String?, name: String? = nil, meeting: String? = nil, media: Bool = false,
              detectors: Set<ModeDetector>? = nil) -> ModeReading {
        ModeRules.read(ModeSignals(appInFront: app, appName: name, meeting: meeting, mediaPlaying: media), detectors: detectors ?? all)
    }

    func testTheAppInFrontPointsToAModeAndSaysSo() {
        XCTAssertEqual(read("com.apple.dt.Xcode", name: "Xcode"), ModeReading(.developer, "Xcode is in front"))
        XCTAssertEqual(read("com.jetbrains.intellij").mode, .developer)
        XCTAssertEqual(read("com.figma.Desktop", name: "Figma"), ModeReading(.creative, "Figma is in front"))
        XCTAssertEqual(read("com.adobe.Photoshop.2027").mode, .creative)
        XCTAssertEqual(read("us.zoom.xos", name: "zoom.us").mode, .meeting)
        XCTAssertEqual(read("com.spotify.client", name: "Spotify").mode, .media)
        XCTAssertEqual(read("com.apple.Safari", name: "Safari"), .none)
        XCTAssertEqual(read("com.apple.iCal", name: "Calendar"), .none, "Calendar in front is planning, not a call")
        XCTAssertEqual(read(nil), .none)
    }

    func testACallComesFirstAndMediaOnlyWhenNothingElsePointsAnywhere() {
        XCTAssertEqual(read("com.apple.dt.Xcode", meeting: "Standup"), ModeReading(.meeting, "“Standup” is on"))
        XCTAssertEqual(read("com.apple.dt.Xcode", media: true).mode, .developer, "Coding with music on is still coding")
        XCTAssertEqual(read("com.apple.Safari", media: true), ModeReading(.media, "Music is playing"))
    }

    func testEachDetectorCanBeSwitchedOff() {
        XCTAssertEqual(read("com.apple.dt.Xcode", meeting: "Standup", detectors: [.apps, .media]).mode, .developer)
        XCTAssertEqual(read("com.apple.dt.Xcode", detectors: [.meetings, .media]), .none)
        XCTAssertEqual(read(nil, media: true, detectors: [.apps, .meetings]), .none)
        XCTAssertEqual(read("com.apple.dt.Xcode", meeting: "Standup", media: true, detectors: []), .none)
    }

    func testStudyIsOnlyEverChosen() {
        XCTAssertFalse(WorkMode.study.inferable)
        for app in ["com.apple.Preview", "com.apple.Notes", "com.apple.iBooksX", "com.apple.Safari"] {
            XCTAssertNotEqual(read(app).mode, .study, app)
        }
    }

    func testAGlanceAtAnotherAppDoesntFlipTheMode() {
        var tracker = ModeTracker(settle: 15)
        let xcode = ModeReading(.developer, "Xcode is in front")
        XCTAssertFalse(tracker.observe(xcode, at: t0))
        XCTAssertTrue(tracker.observe(xcode, at: t0.addingTimeInterval(15)), "Held for the settle time")
        XCTAssertEqual(tracker.current.mode, .developer)
        XCTAssertFalse(tracker.observe(ModeReading(.creative, "Figma is in front"), at: t0.addingTimeInterval(20)))
        XCTAssertEqual(tracker.settlesAt, t0.addingTimeInterval(35))
        XCTAssertFalse(tracker.observe(ModeReading(.developer, "Terminal is in front"), at: t0.addingTimeInterval(25)))
        XCTAssertEqual(tracker.current, ModeReading(.developer, "Terminal is in front"), "Same mode, fresher reason")
        XCTAssertNil(tracker.pending, "Coming back cancels the pending change")
        XCTAssertFalse(tracker.observe(ModeReading(.creative, "Figma is in front"), at: t0.addingTimeInterval(40)))
        XCTAssertFalse(tracker.observe(ModeReading(.creative, "Figma is in front"), at: t0.addingTimeInterval(50)))
        XCTAssertTrue(tracker.observe(ModeReading(.creative, "Figma is in front"), at: t0.addingTimeInterval(55)))
    }

    func testACallStartsTheMeetingModeAtOnceAndLeavingItSettles() {
        var tracker = ModeTracker(settle: 15)
        XCTAssertTrue(tracker.observe(ModeReading(.meeting, "“Standup” is on"), at: t0))
        XCTAssertFalse(tracker.observe(.none, at: t0.addingTimeInterval(1)), "A call ending doesn't flap the mode")
        XCTAssertEqual(tracker.current.mode, .meeting)
        XCTAssertTrue(tracker.observe(.none, at: t0.addingTimeInterval(16)))
        XCTAssertEqual(tracker.current.mode, .general)
    }

    func testEveryModeOffersThreeDistinctShortcutsAndGeneralKeepsTodaysOnes() {
        for mode in WorkMode.allCases {
            XCTAssertEqual(mode.shortcuts.count, 3, mode.rawValue)
            XCTAssertEqual(Set(mode.shortcuts).count, 3, mode.rawValue)
        }
        XCTAssertEqual(WorkMode.general.shortcuts, [.music, .shelf, .tools])
        XCTAssertEqual(WorkMode.developer.boosted, [.agent, .build, .ci, .deploy])
        XCTAssertTrue(WorkMode.creative.boosted.isEmpty)
    }

    func testModesTiltSuggestionsAndCallsMakeThemQuieter() throws {
        let copy = { (text: String) in
            ContextEvent(.clipboard(ClipboardSignal(text: text, sourceApp: "com.apple.dt.Xcode", sourceName: "Xcode")), at: self.t0)
        }
        var engine = IntentEngine()
        var creative = IntentSituation(); creative.mode = .creative
        guard case .suggest(let color) = engine.evaluate(copy("#0A84FF"), in: creative) else { return XCTFail("Should suggest") }
        XCTAssertTrue(color.components.contains(ScoreComponent("Creative mode", 0.08)))
        XCTAssertEqual(color.score, 0.83, accuracy: 0.0001)

        var meeting = IntentSituation(); meeting.mode = .meeting
        var calls = IntentEngine()
        guard case .hold(.belowThreshold, _, let components) = calls.evaluate(copy("https://example.com/notes"), in: meeting)
        else { return XCTFail("A link is held during a call") }
        XCTAssertTrue(components.contains(ScoreComponent("In a call", -0.15)))

        let passage = Array(repeating: "word", count: 45).joined(separator: " ")
        var general = IntentEngine()
        guard case .hold(.belowThreshold, _, _) = general.evaluate(copy(passage), in: IntentSituation()) else {
            return XCTFail("Long text is held in General")
        }
        var study = IntentSituation(); study.mode = .study
        var studying = IntentEngine()
        guard case .suggest = studying.evaluate(copy(passage), in: study) else { return XCTFail("Study lifts long text over the bar") }
    }
}
