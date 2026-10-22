import XCTest
@testable import NotchCore

final class ActionChainTests: XCTestCase {
    func testEachStepSaysWhatItMakesAndResultsThatAreShownDontChain() {
        XCTAssertEqual(ActionChains.output(of: .resizeHalf, from: .image), .image)
        XCTAssertEqual(ActionChains.output(of: .exportPages, from: .pdf), .image)
        XCTAssertEqual(ActionChains.output(of: .createArchive, from: .video), .file)
        XCTAssertEqual(ActionChains.output(of: .qrCode, from: .link), .image)
        XCTAssertNil(ActionChains.output(of: .compress, from: .pdf), "Compress takes images")
        XCTAssertNil(ActionChains.output(of: .pdfText, from: .pdf), "Text is shown, not made into a file")
        XCTAssertNil(ActionChains.output(of: .createArchive, from: .text), "Text has no file to archive")
        XCTAssertEqual(ActionChains.scope(of: .mergePDFs), .all)
        XCTAssertEqual(ActionChains.scope(of: .compress), .each)
    }

    func testEveryPresetFitsTogetherForWhatItAccepts() {
        for chain in ActionChain.presets {
            for kind in chain.accepts { XCTAssertNotNil(chain.output(from: kind), "\(chain.id) from \(kind)") }
            XCTAssertGreaterThan(chain.steps.count, 1, "\(chain.id) is a chain")
            XCTAssertTrue(chain.steps.allSatisfy { $0.effect == .createsFile }, "\(chain.id) only makes new files")
        }
        XCTAssertEqual(Set(ActionChain.presets.map(\.id)).count, ActionChain.presets.count)
    }

    func testAChainOffersItselfOnlyForWhatItCanTake() {
        XCTAssertEqual(ActionChain.applicable(to: [.image]).map(\.id), ["web-ready-images"])
        XCTAssertEqual(ActionChain.applicable(to: [.image, .image]).map(\.id), ["web-ready-images", "compress-and-zip"])
        XCTAssertEqual(ActionChain.applicable(to: [.pdf]).map(\.id), ["pages-as-images"])
        XCTAssertEqual(ActionChain.applicable(to: [.pdf, .pdf]).map(\.id), ["document-bundle", "pages-as-images"])
        XCTAssertTrue(ActionChain.applicable(to: [.image, .pdf]).isEmpty, "Mixed kinds don't fit one chain")
        XCTAssertTrue(ActionChain.applicable(to: []).isEmpty)
        XCTAssertTrue(ActionChain.applicable(to: [.text]).isEmpty)
    }

    func testProgressCountsFinishedStepsAndNeverInventsANumber() {
        let chain = ActionChain.presets[0]
        var progress = ChainProgress(chain: chain)
        XCTAssertEqual(progress.label, "Step 1 of 2 · Resize to Half")
        XCTAssertEqual(progress.overall, 0.25, accuracy: 0.0001, "An unmeasured step counts as half done")
        progress.report(1)
        XCTAssertEqual(progress.overall, 0.5, accuracy: 0.0001)
        progress.begin(step: 1)
        XCTAssertEqual(progress.label, "Step 2 of 2 · Compress")
        progress.report(0.5)
        XCTAssertEqual(progress.overall, 0.75, accuracy: 0.0001)
        progress.report(.nan)
        XCTAssertEqual(progress.overall, 0.75, accuracy: 0.0001)
    }

    func testOnlyTheLastStepsFilesAreKeptAndOriginalsAreNeverRemoved() {
        var artifacts = ChainArtifacts(inputs: ["a.png", "b.png"])
        artifacts.stepFinished(made: ["a-half.png", "b-half.png"])
        artifacts.stepFinished(made: ["a-small.jpg", "b-small.jpg"])
        let finished = artifacts.finished()
        XCTAssertEqual(finished.keep, ["a-small.jpg", "b-small.jpg"])
        XCTAssertEqual(finished.remove, ["a-half.png", "b-half.png"])
        XCTAssertFalse(finished.remove.contains("a.png"))
    }

    func testACancelledOrFailedRunRemovesEverythingItMadeAndNothingElse() {
        var artifacts = ChainArtifacts(inputs: ["a.pdf", "b.pdf"])
        artifacts.stepFinished(made: ["merged.pdf"])
        XCTAssertEqual(artifacts.abandon(), ["merged.pdf"])
        var early = ChainArtifacts(inputs: ["a.pdf"])
        XCTAssertEqual(early.abandon(), [], "Cancelled before any step finished: nothing to remove, originals stay")
    }

    func testTheNextActionFollowsWhatWasJustMade() {
        XCTAssertEqual(NextActionRules.after(.resizeHalf, made: .image, count: 1).map(\.action), [.compress])
        XCTAssertEqual(NextActionRules.after(.compress, made: .image, count: 1).map(\.action), [.copy])
        XCTAssertEqual(NextActionRules.after(.removeBackground, made: .image, count: 1).map(\.action), [.copy],
                       "Compressing would lose the transparency just made")
        XCTAssertEqual(NextActionRules.after(.exportPages, made: .image, count: 6).map(\.action), [.createArchive])
        XCTAssertEqual(NextActionRules.after(.compress, made: .image, count: 3).map(\.action), [.createArchive, .copy],
                       "Several new files: an archive first")
        XCTAssertEqual(NextActionRules.after(.mergePDFs, made: .pdf, count: 1).map(\.action), [.pdfText])
        XCTAssertEqual(NextActionRules.after(.createArchive, made: .file, count: 1).map(\.action), [.copy])
        XCTAssertEqual(NextActionRules.after(.qrCode, made: .image, count: 1).first?.reason, "Copy it, ready to paste")
        XCTAssertTrue(NextActionRules.after(.convertM4A, made: .audio, count: 1).isEmpty)
        for action in ContentAction.allCases {
            XCTAssertFalse(NextActionRules.after(action, made: .image, count: 2).contains { $0.action == action }, "\(action) never suggests itself")
        }
    }

    func testAChainRunMovesThroughItsStepsAsOneAttempt() {
        var run = ActionRun()
        let token = run.start(.resizeHalf)!
        run.advance(to: .compress, token: token)
        XCTAssertEqual(run.phase, .processing(.compress, progress: nil))
        run.advance(to: .createArchive, token: token + 1)
        XCTAssertEqual(run.phase, .processing(.compress, progress: nil), "A stale attempt can't move it")
        run.finish(.created(["a.zip"]), token: token)
        XCTAssertEqual(run.phase, .completed(.compress, .created(["a.zip"])), "The result belongs to the last step")
        run.advance(to: .copy, token: token)
        XCTAssertEqual(run.phase, .completed(.compress, .created(["a.zip"])), "A finished run doesn't move")
    }

    func testLinksOfferAQRCodeAndFilesCanGoIntoAnArchive() {
        XCTAssertTrue(ActionRegistry.actions(for: ContentContext(kind: .link, title: "x")).contains(.qrCode))
        XCTAssertTrue(ActionRegistry.actions(for: ContentClassifier.collection([.image, .pdf, .video])).contains(.createArchive))
        XCTAssertEqual(ActionRegistry.actions(for: ContentClassifier.collection([.pdf, .pdf])), [.mergePDFs, .createArchive])
        XCTAssertFalse(ActionRegistry.actions(for: ContentClassifier.collection([.text, .image])).contains(.createArchive))
        XCTAssertTrue(ActionRegistry.actions(for: ContentContext(kind: .folder, title: "x")).contains(.createArchive))
        XCTAssertEqual(ActionCatalog.descriptor(for: .createArchive).undo, .removesCreated)
        XCTAssertEqual(ActionCatalog.descriptor(for: .qrCode).impact, .createsFile)
    }
}
