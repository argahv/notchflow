import XCTest
@testable import NotchCore

final class FlowGuardianTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_930_132_800)

    func testASessionCountsWhatWaitedOnceAndForgetsItAfterwards() throws {
        var ledger = FocusLedger()
        ledger.note(id: "before", kind: .update, title: "Ignored outside a session")
        XCTAssertTrue(ledger.entries.isEmpty)
        ledger.begin(at: t0)
        XCTAssertTrue(ledger.focusing)
        ledger.note(id: "qa:build", kind: .update, title: "Build finished")
        ledger.note(id: "qa:build", kind: .update, title: "Build finished")
        ledger.note(id: "qa:ci", kind: .update, title: "CI passed")
        ledger.note(id: "copy-1", kind: .suggestion, title: "Colors")
        let summary = try XCTUnwrap(ledger.end(at: t0.addingTimeInterval(25 * 60), completed: true))
        XCTAssertEqual(summary.updates, ["qa:build", "qa:ci"])
        XCTAssertEqual(summary.waited, 3)
        XCTAssertEqual(summary.title, "Focus session finished")
        XCTAssertEqual(summary.detail, "25 min · 2 updates and 1 suggestion waited")
        XCTAssertFalse(ledger.active)
        XCTAssertNil(ledger.end(at: t0, completed: true), "Nothing to end twice")
    }

    func testPausesDontCountAsFocusAndNothingIsHeldWhilePaused() throws {
        var ledger = FocusLedger()
        ledger.begin(at: t0)
        ledger.pause(at: t0.addingTimeInterval(10 * 60))
        XCTAssertFalse(ledger.focusing)
        XCTAssertTrue(ledger.active)
        ledger.resume(at: t0.addingTimeInterval(25 * 60))
        let summary = try XCTUnwrap(ledger.end(at: t0.addingTimeInterval(40 * 60), completed: false))
        XCTAssertEqual(summary.focused, 25 * 60)
        XCTAssertEqual(summary.title, "Focus session ended early")
        XCTAssertEqual(summary.detail, "25 min · nothing waited")
    }

    func testLongSessionsReadInHoursAndShortOnesAsAMinute() throws {
        var long = FocusLedger(); long.begin(at: t0)
        long.note(id: "a", kind: .update, title: "A")
        XCTAssertEqual(try XCTUnwrap(long.end(at: t0.addingTimeInterval(75 * 60), completed: true)).detail, "1 h 15 min · 1 update waited")
        var short = FocusLedger(); short.begin(at: t0)
        XCTAssertEqual(try XCTUnwrap(short.end(at: t0.addingTimeInterval(10), completed: true)).detail, "1 min · nothing waited")
    }

    func testOnlyWorkThatNeedsYouComesThroughDuringFocus() {
        let focus = AttentionContext(holdBelow: FlowGuardian.lowestPriorityDuringFocus)
        var center = AttentionCenter()
        let done = AttentionItem(id: "build", priority: .informational, arrived: t0)
        let input = AttentionItem(id: "agent", priority: .actionRequired, arrived: t0.addingTimeInterval(5))
        XCTAssertEqual(center.receive(done, context: focus), .indicate)
        XCTAssertEqual(center.receive(input, context: focus), .present(input))
    }

    func testSuggestionsWaitForTheEndOfAFocusSession() {
        var engine = IntentEngine()
        var focusing = IntentSituation(); focusing.focusing = true
        let copy = ContextEvent(.clipboard(ClipboardSignal(text: "#0A84FF")), at: t0)
        guard case .hold(.focusSession, _, _) = engine.evaluate(copy, in: focusing) else { return XCTFail("Held during focus") }
        guard case .suggest = engine.evaluate(copy, in: IntentSituation()) else { return XCTFail("Suggested afterwards") }
    }
}

final class DownloadSuggestionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_930_132_800)

    func finished(_ name: String, kind: ContentKind, archive: Bool = false, size: Int64? = 2_400_000) -> ContextEvent {
        ContextEvent(.download(DownloadSignal(name: name, path: "/Users/qa/Downloads/" + name, byteCount: size, kind: kind, isArchive: archive)),
                     at: t0)
    }
    func suggestion(_ decision: IntentDecision) -> Suggestion? {
        if case .suggest(let suggestion) = decision { return suggestion }
        return nil
    }

    func testAnArchiveOffersToExtractItAndKeepsShowInFinder() throws {
        var engine = IntentEngine()
        let archive = try XCTUnwrap(suggestion(engine.evaluate(finished("assets.zip", kind: .file, archive: true), in: IntentSituation())))
        XCTAssertEqual(archive.rule, "download.archive")
        XCTAssertEqual(archive.actions, [.extractArchive(path: "/Users/qa/Downloads/assets.zip"), .reveal(path: "/Users/qa/Downloads/assets.zip")])
        XCTAssertEqual(archive.title, "Archive downloaded")
        XCTAssertTrue(archive.detail.hasPrefix("assets.zip · "))
        XCTAssertEqual(archive.category, .downloads)
    }

    func testAPDFOffersExtractTextThenShowInFinderThenItsOtherActions() throws {
        var engine = IntentEngine()
        let pdf = try XCTUnwrap(suggestion(engine.evaluate(finished("invoice.pdf", kind: .pdf), in: IntentSituation())))
        let path = "/Users/qa/Downloads/invoice.pdf"
        XCTAssertEqual(pdf.actions, [.openActions(path: path, then: .pdfText), .reveal(path: path), .openActions(path: path, then: nil)])
        XCTAssertEqual(pdf.actions.map(\.title), ["Extract Text", "Show in Finder", "Actions…"])
    }

    func testImagesAndMediaOfferActionsAndOtherFilesKeepThePlainNotice() {
        var engine = IntentEngine()
        XCTAssertEqual(suggestion(engine.evaluate(finished("photo.jpg", kind: .image), in: IntentSituation()))?.rule, "download.image")
        XCTAssertEqual(suggestion(engine.evaluate(finished("clip.mov", kind: .video), in: IntentSituation()))?.rule, "download.media")
        guard case .hold(.nothingToOffer, _, _) = engine.evaluate(finished("notes.txt", kind: .text), in: IntentSituation()) else {
            return XCTFail("A text file keeps the download's own notice")
        }
        guard case .hold(.nothingToOffer, _, _) = engine.evaluate(finished("Installer.dmg", kind: .file), in: IntentSituation()) else {
            return XCTFail("A disk image isn't an archive to extract")
        }
    }

    func testAFinishedDownloadIsContentAndItsSummaryNeverNamesTheFile() {
        let event = finished("medical-report.pdf", kind: .pdf, size: 1_048_576)
        XCTAssertEqual(event.privacy, .content)
        XCTAssertEqual(event.source, .downloads)
        XCTAssertFalse(event.redactedSummary.contains("medical"))
        XCTAssertTrue(event.redactedSummary.hasPrefix("Downloaded a PDF · "))
        XCTAssertEqual(ContextEvent(.download(DownloadSignal(name: "n.txt", path: "/n.txt", kind: .text)), at: t0).redactedSummary,
                       "Downloaded a text file")
        var hidden = IntentSituation(); hidden.privateMode = true
        var engine = IntentEngine()
        guard case .hold(.detailsHidden, _, _) = engine.evaluate(event, in: hidden) else { return XCTFail("Hidden while presenting") }
    }

    func testTheSameFileReportedTwiceInAMinuteIsOneDownload() {
        var gate = ContextGate()
        XCTAssertEqual(gate.admit(finished("a.zip", kind: .file, archive: true)), .pass)
        XCTAssertEqual(gate.admit(ContextEvent(finished("a.zip", kind: .file, archive: true).signal, at: t0.addingTimeInterval(30))), .duplicate)
        XCTAssertEqual(gate.admit(ContextEvent(finished("b.zip", kind: .file, archive: true).signal, at: t0.addingTimeInterval(31))), .pass,
                       "Downloads aren't throttled: each file passes at once")
    }

    func testDownloadActionsDeclareThatTheyLeaveTheOriginalAlone() {
        let extract = ActionCatalog.descriptor(for: .extractArchive(path: "/tmp/a.zip"))
        XCTAssertEqual(extract.impact, .opensElsewhere)
        let actions = ActionCatalog.descriptor(for: .openActions(path: "/tmp/a.pdf", then: .pdfText))
        XCTAssertEqual(actions.impact, .createsRecord)
        XCTAssertEqual(ActionGuard.clearance(for: actions, granted: [], confirmed: false), .run)
    }
}
