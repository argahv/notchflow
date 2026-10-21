import XCTest
@testable import NotchCore

final class ContentActionTests: XCTestCase {
    // MARK: Classification

    func testFilesAreClassifiedByTheirTypes() {
        func kind(_ lineage: Set<String>, directory: Bool = false, package: Bool = false) -> ContentKind {
            ContentClassifier.kind(lineage: lineage, isDirectory: directory, isPackage: package)
        }
        XCTAssertEqual(kind(["public.png", "public.image"]), .image)
        XCTAssertEqual(kind(["com.adobe.pdf"]), .pdf)
        XCTAssertEqual(kind(["public.mpeg-4", "public.movie"]), .video)
        XCTAssertEqual(kind(["public.mp3", "public.audio"]), .audio)
        XCTAssertEqual(kind(["public.swift-source", "public.source-code", "public.plain-text"]), .code, "code before plain text")
        XCTAssertEqual(kind(["public.json", "public.text"]), .code)
        XCTAssertEqual(kind(["public.plain-text", "public.text"]), .text)
        XCTAssertEqual(kind(["public.folder"], directory: true), .folder)
        XCTAssertEqual(kind(["com.apple.application-bundle"], directory: true, package: true), .file)
        XCTAssertEqual(kind(["com.microsoft.word.doc"]), .file)
    }

    func testTextIsALinkCodeOrProse() {
        XCTAssertEqual(ContentClassifier.kind(ofText: "https://developer.apple.com/documentation"), .link)
        XCTAssertEqual(ContentClassifier.kind(ofText: "func greet() {\n    let name = \"A\";\n}"), .code)
        XCTAssertEqual(ContentClassifier.kind(ofText: "Ship the portal on Friday."), .text)
    }

    // MARK: Availability

    func testEachKindOffersItsMostUsefulActionsFirst() {
        XCTAssertEqual(ActionRegistry.primary(for: ContentContext(kind: .image, title: "a.png")), [.extractText, .removeBackground])
        XCTAssertEqual(ActionRegistry.primary(for: ContentContext(kind: .pdf, title: "a.pdf")), [.pdfText, .exportPages])
        XCTAssertEqual(ActionRegistry.primary(for: ContentContext(kind: .text, title: "Note")), [.createNote, .copy])
        XCTAssertEqual(ActionRegistry.primary(for: ContentContext(kind: .link, title: "example.com")), [.open, .copy])
        XCTAssertEqual(ActionRegistry.primary(for: ContentContext(kind: .video, title: "a.mov")), [.extractFrame, .mediaInfo])
        XCTAssertFalse(ActionRegistry.actions(for: ContentContext(kind: .pdf, title: "a.pdf", pageCount: 1)).contains(.splitPages),
                       "a one-page PDF has nothing to split")
    }

    func testSecretsAreNeverCopiedSomewhereNew() {
        let secret = ContentContext(kind: .text, title: "sk-…", sensitive: true)
        XCTAssertEqual(ActionRegistry.actions(for: secret), [.copy, .wordCount])
        XCTAssertFalse(ActionRegistry.actions(for: ContentContext(kind: .code, title: "env", sensitive: true)).contains(.createNote))
    }

    func testCollectionsOfferMergeOnlyForSeveralPDFs() {
        XCTAssertEqual(ActionRegistry.actions(for: ContentClassifier.collection([.pdf, .pdf, .pdf], title: "3 PDFs")), [.mergePDFs])
        XCTAssertTrue(ActionRegistry.actions(for: ContentClassifier.collection([.pdf, .image], title: "2 files")).isEmpty)
        XCTAssertTrue(ActionRegistry.actions(for: ContentClassifier.collection([.pdf], title: "1 PDF")).isEmpty)
    }

    func testEffectsSayWhatHappensToTheData() {
        XCTAssertEqual(ContentAction.removeBackground.effect, .createsFile)
        XCTAssertEqual(ContentAction.linkPreview.effect, .network, "the only action that uses the internet")
        XCTAssertEqual(ContentAction.extractText.effect, .local)
        XCTAssertEqual(ContentAction.allCases.filter { $0.effect == .network }, [.linkPreview])
    }

    // MARK: Lifecycle

    func testARunMovesThroughItsStatesOnce() throws {
        var run = ActionRun()
        let token = try XCTUnwrap(run.start(.compressVideo))
        XCTAssertNil(run.start(.extractFrame), "one action at a time")
        XCTAssertEqual(run.phase, .processing(.compressVideo, progress: nil), "indeterminate until measured")
        run.progress(0.4, token: token); XCTAssertEqual(run.phase, .processing(.compressVideo, progress: 0.4))
        run.progress(7, token: token); XCTAssertEqual(run.phase, .processing(.compressVideo, progress: 1))
        run.finish(.created(["a.mov"]), token: token)
        XCTAssertEqual(run.phase, .completed(.compressVideo, .created(["a.mov"])))
        run.fail("late", token: token); XCTAssertEqual(run.phase, .completed(.compressVideo, .created(["a.mov"])), "a finished run stays finished")
        run.reset(); XCTAssertEqual(run.phase, .available)
    }

    func testCancelledOrReplacedRunsCantOverwriteTheState() throws {
        var run = ActionRun()
        let first = try XCTUnwrap(run.start(.pdfText))
        run.cancel(); XCTAssertEqual(run.phase, .available)
        run.finish(.text("stale"), token: first); XCTAssertEqual(run.phase, .available, "a cancelled run finishing late is ignored")
        let second = try XCTUnwrap(run.start(.pdfText))
        run.finish(.text("old"), token: first); XCTAssertEqual(run.phase, .processing(.pdfText, progress: nil))
        run.fail("Couldn't read it", token: second); XCTAssertEqual(run.phase, .failed(.pdfText, "Couldn't read it"))
        XCTAssertNotNil(run.start(.pdfText), "a failed action can be retried")
    }

    // MARK: Text

    func testTextTransformsAreExact() {
        XCTAssertEqual(TextTransforms.titleCase("ship the API on friday-night (today)"), "Ship The API On Friday-Night (Today)")
        XCTAssertEqual(TextTransforms.cleanWhitespace("  a   b \t c  \n\n\n\n  d  \r\n e \n\n"), "a b c\n\nd\ne")
        XCTAssertEqual(TextTransforms.words("Ship it, today — really."), 4)
        XCTAssertEqual(TextTransforms.details("a b\nc").map(\.value), ["3", "5", "2"])
        XCTAssertEqual(TextTransforms.uppercase("Mixed"), "MIXED")
    }

    func testCodeLanguageIsGuessedOnlyWhenClear() {
        XCTAssertEqual(CodeLanguage.detect("import SwiftUI\nstruct A: View {\n  var body: some View { Text(\"a\") }\n}"), "Swift")
        XCTAssertEqual(CodeLanguage.detect("def greet(name):\n    print(name)\n    return None"), "Python")
        XCTAssertEqual(CodeLanguage.detect("SELECT name FROM users WHERE id = 1"), "SQL")
        XCTAssertEqual(CodeLanguage.detect("{\"a\": [1, 2, {\"b\": true}]}"), "JSON")
        XCTAssertNil(CodeLanguage.detect("just some words here"))
    }
}
