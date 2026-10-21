import XCTest
@testable import NotchCore

final class ScreenshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Detection

    func testOnlyFreshVisibleImagesCreatedWhileWatchingAreCandidates() {
        let since = now.addingTimeInterval(-60)
        XCTAssertTrue(ScreenshotRules.isCandidate(name: "Screenshot 2026-10-21 at 9.41.07 AM.png", created: now.addingTimeInterval(-3), watchingSince: since, now: now))
        XCTAssertTrue(ScreenshotRules.isCandidate(name: "Bildschirmfoto.HEIC", created: now, watchingSince: since, now: now), "any language, any case")
        XCTAssertFalse(ScreenshotRules.isCandidate(name: ".Screenshot 2026-10-21.png", created: now, watchingSince: since, now: now), "macOS writes a hidden file first")
        XCTAssertFalse(ScreenshotRules.isCandidate(name: "notes.txt", created: now, watchingSince: since, now: now))
        XCTAssertFalse(ScreenshotRules.isCandidate(name: "old.png", created: since.addingTimeInterval(-5), watchingSince: since, now: now), "already there before watching began")
        XCTAssertFalse(ScreenshotRules.isCandidate(name: "late.png", created: now.addingTimeInterval(-31), watchingSince: now.addingTimeInterval(-100), now: now), "not just taken")
        XCTAssertFalse(ScreenshotRules.isCandidate(name: "unknown.png", created: nil, watchingSince: since, now: now))
    }

    func testTheScreenCaptureMarkerIsABinaryPlistTrue() throws {
        let yes = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let no = try PropertyListSerialization.data(fromPropertyList: false, format: .binary, options: 0)
        XCTAssertTrue(ScreenshotRules.isScreenCapture(attribute: yes))
        XCTAssertFalse(ScreenshotRules.isScreenCapture(attribute: no))
        XCTAssertFalse(ScreenshotRules.isScreenCapture(attribute: nil), "a downloaded image has no marker")
        XCTAssertFalse(ScreenshotRules.isScreenCapture(attribute: Data("garbage".utf8)))
    }

    func testScreenshotFolderFollowsThePreference() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(ScreenshotRules.folder(location: nil, home: home).path, "/Users/someone/Desktop")
        XCTAssertEqual(ScreenshotRules.folder(location: "  ", home: home).path, "/Users/someone/Desktop")
        XCTAssertEqual(ScreenshotRules.folder(location: "~/Pictures/Screenshots", home: home).path, "/Users/someone/Pictures/Screenshots")
        XCTAssertEqual(ScreenshotRules.folder(location: "/Volumes/Shots", home: home).path, "/Volumes/Shots")
        XCTAssertEqual(ScreenshotRules.folder(location: "relative/path", home: home).path, "/Users/someone/Desktop")
        XCTAssertTrue(ScreenshotRules.savesToFile(target: nil))
        XCTAssertTrue(ScreenshotRules.savesToFile(target: "file"))
        XCTAssertFalse(ScreenshotRules.savesToFile(target: "clipboard"))
        XCTAssertFalse(ScreenshotRules.savesToFile(target: "preview"))
    }

    func testRecentSetReportsEachKeyOnceAndStaysBounded() {
        var seen = RecentSet(capacity: 2)
        XCTAssertTrue(seen.insert("a")); XCTAssertFalse(seen.insert("a"), "a second write event for the same file")
        XCTAssertTrue(seen.insert("b")); XCTAssertTrue(seen.insert("c"))
        XCTAssertFalse(seen.contains("a"), "the oldest key goes when full")
        XCTAssertTrue(seen.contains("b") && seen.contains("c"))
    }

    // MARK: Reading order

    func testRecognisedTextReadsTopToBottomAndLeftToRight() {
        let lines = [
            TextLine(text: "world", x: 0.30, y: 0.101, width: 0.1, height: 0.03),
            TextLine(text: "Second row", x: 0.05, y: 0.15, width: 0.3, height: 0.03),
            TextLine(text: "Hello", x: 0.05, y: 0.10, width: 0.1, height: 0.03),
            TextLine(text: "New paragraph", x: 0.05, y: 0.30, width: 0.3, height: 0.03),
            TextLine(text: "   ", x: 0.5, y: 0.5, width: 0.1, height: 0.03),
        ]
        XCTAssertEqual(TextLayout.readingOrder(lines), "Hello world\nSecond row\n\nNew paragraph")
        XCTAssertEqual(TextLayout.readingOrder([]), "")
    }

    // MARK: Annotation

    func testAnnotationsUndoAndRedoAsSteps() {
        var document = AnnotationDocument()
        let arrow = Annotation(tool: .arrow, start: AnnotationPoint(x: 0.1, y: 0.1), end: AnnotationPoint(x: 0.4, y: 0.3))
        let redact = Annotation(tool: .redact, start: AnnotationPoint(x: 0.5, y: 0.5), end: AnnotationPoint(x: 0.7, y: 0.6))
        document.add(arrow); document.add(redact)
        XCTAssertEqual(document.items.count, 2); XCTAssertEqual(document.redactions, [redact])
        document.undo(); XCTAssertEqual(document.items, [arrow]); XCTAssertTrue(document.canRedo)
        document.redo(); XCTAssertEqual(document.items, [arrow, redact])
        document.undo(); document.add(redact); XCTAssertFalse(document.canRedo, "a new change drops the redo branch")
        document.clear(); XCTAssertTrue(document.items.isEmpty)
        document.undo(); XCTAssertEqual(document.items.count, 2, "clearing is undoable")
    }

    func testStrayClicksAndOutOfBoundsPointsAreTamed() {
        var document = AnnotationDocument()
        document.add(Annotation(tool: .rectangle, start: AnnotationPoint(x: 0.5, y: 0.5), end: AnnotationPoint(x: 0.501, y: 0.5)))
        XCTAssertTrue(document.items.isEmpty, "a click isn't a rectangle"); XCTAssertFalse(document.canUndo)
        let text = Annotation(tool: .text, start: AnnotationPoint(x: 0.2, y: 0.2), end: AnnotationPoint(x: 0.2, y: 0.2), text: "Look")
        document.add(text); XCTAssertEqual(document.items.count, 1, "text is placed with a click")
        document.setText("Look here", for: text.id); XCTAssertEqual(document.items.first?.text, "Look here")
        let clamped = AnnotationPoint(x: -0.4, y: 1.7)
        XCTAssertEqual(clamped, AnnotationPoint(x: 0, y: 1))
        let box = Annotation(tool: .blur, start: AnnotationPoint(x: 0.8, y: 0.6), end: AnnotationPoint(x: 0.2, y: 0.4)).box
        XCTAssertEqual(box.x, 0.2, accuracy: 1e-9); XCTAssertEqual(box.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(box.y, 0.4, accuracy: 1e-9); XCTAssertEqual(box.height, 0.2, accuracy: 1e-9)
        XCTAssertTrue(AnnotationTool.redact.obscures); XCTAssertFalse(AnnotationTool.highlight.obscures)
    }
}
