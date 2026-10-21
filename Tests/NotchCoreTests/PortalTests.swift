import XCTest
@testable import NotchCore

final class PortalTests: XCTestCase {
    // MARK: Stages

    func testPortalStagesFollowTheDragInAndOut() {
        var state = InteractionState()
        state.send(.dragApproach); XCTAssertEqual(state.portal, .aware); XCTAssertEqual(state.awareness, .drag)
        state.send(.dragAttract); XCTAssertEqual(state.portal, .attracted)
        state.send(.beginDrag); XCTAssertEqual(state.portal, .open)
        XCTAssertEqual(state.presentation, .collapsed, "the portal opens in place; it doesn't open the workspace")
        state.send(.dragApproach); XCTAssertEqual(state.portal, .open, "proximity never downgrades a drag that's over the target")
        state.send(.endDrag); XCTAssertEqual(state.portal, .attracted, "leaving the target without dropping")
        state.send(.dragApproach); XCTAssertEqual(state.portal, .aware)
        state.send(.retreat); XCTAssertEqual(state.portal, .closed); XCTAssertEqual(state.awareness, .none)
    }

    func testDropIsAbsorbedThenSettlesToThePreviousState() {
        var state = InteractionState()
        state.send(.dragAttract); state.send(.beginDrag)
        state.send(.retreat); XCTAssertEqual(state.portal, .open, "a mouse-up elsewhere can't close a target that holds the drag")
        state.send(.absorb); XCTAssertEqual(state.portal, .absorbing); XCTAssertFalse(state.dragging)
        state.send(.retreat); XCTAssertEqual(state.portal, .absorbing, "the result stays while the pointer moves away")
        state.send(.settlePortal); XCTAssertEqual(state.portal, .closed); XCTAssertEqual(state.presentation, .collapsed)
    }

    func testPromisedFilesAreReceivedBeforeTheyAreAbsorbed() {
        var state = InteractionState()
        state.send(.beginDrag); XCTAssertEqual(state.portal, .open)
        state.send(.receive); XCTAssertEqual(state.portal, .receiving)
        state.send(.rejectDrop); XCTAssertEqual(state.portal, .failed)
        state.send(.settlePortal); XCTAssertEqual(state.portal, .closed)
    }

    func testCancelledDragRestoresTheRestingNotch() {
        var state = InteractionState()
        state.send(.dragAttract); state.send(.beginDrag); state.send(.endDrag); state.send(.retreat)
        XCTAssertEqual(state, InteractionState(), "nothing left behind after a cancelled drag")
    }

    func testOpenWorkspaceReceivesDropsItselfWithoutAPortal() {
        var state = InteractionState()
        state.send(.expand); state.send(.dragAttract); state.send(.beginDrag)
        XCTAssertEqual(state.portal, .closed); XCTAssertTrue(state.dragging); XCTAssertEqual(state.presentation, .expanded)
        state.send(.absorb); XCTAssertEqual(state.portal, .closed); XCTAssertEqual(state.presentation, .expanded)
    }

    func testPassiveAttentionNeverTakesTheSurfaceFromADragOrItsResult() {
        var state = InteractionState()
        state.send(.dragAttract); state.send(.attention); XCTAssertEqual(state.presentation, .collapsed)
        state.send(.beginDrag); state.send(.absorb); state.send(.attention)
        XCTAssertEqual(state.presentation, .collapsed); XCTAssertEqual(state.portal, .absorbing)
        state.send(.settlePortal); state.send(.attention); XCTAssertEqual(state.presentation, .preview)
    }

    func testExplicitActionsWinOverThePortal() {
        var state = InteractionState()
        state.send(.dragAttract); state.send(.expand); XCTAssertEqual(state.portal, .closed)
        state = InteractionState(); state.send(.beginDrag); state.send(.dismiss)
        XCTAssertEqual(state, InteractionState())
    }

    // MARK: Cargo

    func testEligibilityComesFromTypesOnly() {
        XCTAssertTrue(PortalRules.isEligible(types: ["public.file-url", "com.apple.finder.node"]))
        XCTAssertTrue(PortalRules.isEligible(types: ["com.apple.NSFilePromiseItemMetaData"]))
        XCTAssertTrue(PortalRules.isEligible(types: ["public.url", "public.utf8-plain-text"]))
        XCTAssertTrue(PortalRules.isEligible(types: ["public.rtf"]))
        XCTAssertFalse(PortalRules.isEligible(types: []), "a window drag carries nothing")
        XCTAssertFalse(PortalRules.isEligible(types: ["com.apple.private.custom", "dyn.ah62d4rv4gu8y"]))
    }

    func testEachItemCountsOnceByItsStrongestKind() {
        let finderFile = ["public.file-url", "public.utf8-plain-text", "com.apple.finder.node"]
        let browserImage = ["public.url", "public.tiff", "public.utf8-plain-text"]
        let link = ["public.url", "public.utf8-plain-text"]
        let promisedPicture = ["com.apple.pasteboard.promised-file-url", "public.url", "public.tiff"]
        let mailAttachment = ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type"]
        let linkWithPromise = ["public.url", "com.apple.pasteboard.promised-file-url", "public.utf8-plain-text"]
        XCTAssertEqual(PortalRules.kind(ofItemTypes: finderFile), .file)
        XCTAssertEqual(PortalRules.kind(ofItemTypes: browserImage), .image)
        XCTAssertEqual(PortalRules.kind(ofItemTypes: link), .link)
        XCTAssertEqual(PortalRules.kind(ofItemTypes: promisedPicture), .image, "a browser picture is an image, not a file")
        XCTAssertEqual(PortalRules.kind(ofItemTypes: mailAttachment), .file)
        XCTAssertEqual(PortalRules.kind(ofItemTypes: linkWithPromise), .file, "types alone can't tell; the drop itself prefers the link")
        XCTAssertEqual(PortalRules.cargo(itemTypes: [finderFile, finderFile, finderFile]), PortalCargo(kind: .file, count: 3))
        XCTAssertEqual(PortalRules.cargo(itemTypes: [finderFile, link])?.kind, .mixed)
        XCTAssertNil(PortalRules.cargo(itemTypes: [["com.apple.private.custom"]]))
    }

    func testFilesAreNamedByWhatTheyAre() {
        func kind(_ lineage: Set<String>, directory: Bool = false, package: Bool = false) -> PortalContentKind {
            PortalRules.kind(ofFileType: lineage, isDirectory: directory, isPackage: package)
        }
        XCTAssertEqual(kind(["public.png", "public.image", "public.data"]), .image)
        XCTAssertEqual(kind(["com.adobe.pdf", "public.data"]), .pdf)
        XCTAssertEqual(kind(["com.apple.quicktime-movie", "public.movie"]), .video)
        XCTAssertEqual(kind(["public.mp3", "public.audio"]), .audio)
        XCTAssertEqual(kind(["public.folder"], directory: true), .folder)
        XCTAssertEqual(kind(["com.apple.application-bundle"], directory: true, package: true), .file, "an app is a file, not a folder")

        XCTAssertEqual(PortalRules.cargo(files: [("Report.pdf", .pdf)])?.title, "Report.pdf")
        XCTAssertEqual(PortalRules.cargo(files: [("a.png", .image), ("b.png", .image)])?.title, "2 images")
        XCTAssertEqual(PortalRules.cargo(files: [("a.png", .image), ("b.pdf", .pdf), ("c", .folder)])?.title, "3 files")
        XCTAssertEqual(PortalCargo(kind: .link, count: 1, name: "ignored").title, "Link", "links and text never show a file name")
        XCTAssertEqual(PortalCargo(kind: .mixed, count: 4).title, "4 items")
        XCTAssertNil(PortalRules.cargo(files: []))
    }

    // MARK: Shelf policy

    func testOnlyASingleWebAddressBecomesALink() {
        XCTAssertEqual(ShelfPolicy.link(from: "  https://example.com/a?b=1 \n")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertNil(ShelfPolicy.link(from: "javascript:alert(1)"))
        XCTAssertNil(ShelfPolicy.link(from: "file:///etc/passwd"))
        XCTAssertNil(ShelfPolicy.link(from: "https://"), "a web link needs a host")
        XCTAssertNil(ShelfPolicy.link(from: "see https://example.com"), "a sentence with a link is text")
        XCTAssertNil(ShelfPolicy.link(from: "https://example.com/" + String(repeating: "a", count: 5000)))
    }

    func testTextLimitsAndDuplicateKeys() {
        XCTAssertNil(ShelfPolicy.admit(text: "hello"))
        XCTAssertEqual(ShelfPolicy.admit(text: "  \n "), .empty)
        XCTAssertEqual(ShelfPolicy.admit(text: String(repeating: "x", count: ShelfPolicy.maxTextBytes + 1)), .textTooLong)
        XCTAssertEqual(ShelfPolicy.key(forText: "same"), ShelfPolicy.key(forText: "same"))
        XCTAssertNotEqual(ShelfPolicy.key(forText: "same"), ShelfPolicy.key(forText: "Same"))
        XCTAssertEqual(ShelfPolicy.key(forLink: URL(string: "https://example.com/")!), ShelfPolicy.key(forLink: URL(string: "https://example.com")!))
        XCTAssertTrue(ShelfPolicy.fits(existing: 99, adding: 1)); XCTAssertFalse(ShelfPolicy.fits(existing: 99, adding: 2))
    }

    func testCopiesAreBounded() {
        XCTAssertNil(ShelfPolicy.admitCopy(bytes: 10_000, ownedTotal: 0, name: "a.png"))
        XCTAssertEqual(ShelfPolicy.admitCopy(bytes: ShelfPolicy.maxOwnedItemBytes + 1, ownedTotal: 0, name: "big.mov"), .tooLarge("big.mov"))
        XCTAssertEqual(ShelfPolicy.admitCopy(bytes: 10, ownedTotal: ShelfPolicy.maxOwnedTotalBytes, name: "a"), .ownedSpaceFull)
    }

    func testTitlesAreShortAndReadable() {
        XCTAssertEqual(ShelfPolicy.title(forText: "\n\n  First line  \nsecond"), "First line")
        XCTAssertEqual(ShelfPolicy.title(forText: "   "), "Text")
        XCTAssertEqual(ShelfPolicy.title(forText: String(repeating: "a", count: 80)).count, 60)
        XCTAssertEqual(ShelfPolicy.title(forLink: URL(string: "https://www.example.com/docs/page")!), "example.com/docs/page")
        XCTAssertEqual(ShelfPolicy.title(forLink: URL(string: "https://example.com/")!), "example.com")
    }

    func testNamesForCopiesCannotEscapeTheShelfFolder() {
        XCTAssertEqual(ShelfPolicy.safeFileName("../../etc/passwd", fallback: "Item"), "-..-etc-passwd")
        XCTAssertEqual(ShelfPolicy.safeFileName("..", fallback: "Item"), "Item")
        XCTAssertEqual(ShelfPolicy.safeFileName(".hidden", fallback: "Item"), "hidden")
        XCTAssertEqual(ShelfPolicy.safeFileName("a:b\\c\u{0}d.png", fallback: "Item"), "a-b-c-d.png")
        XCTAssertEqual(ShelfPolicy.safeFileName("   ", fallback: "Item"), "Item")
        let long = ShelfPolicy.safeFileName(String(repeating: "n", count: 300) + ".jpeg", fallback: "Item")
        XCTAssertEqual(long.count, 115); XCTAssertTrue(long.hasSuffix(".jpeg"))
        XCTAssertFalse(ShelfPolicy.safeFileName("x/y", fallback: "Item").contains("/"))
    }

    func testOrphanedCopiesAreFound() {
        XCTAssertEqual(ShelfPolicy.orphans(onDisk: ["b/2.png", "a/1.pdf", "c/3.txt"], referenced: ["a/1.pdf"]), ["b/2.png", "c/3.txt"])
        XCTAssertTrue(ShelfPolicy.orphans(onDisk: [], referenced: ["a"]).isEmpty)
    }
}
