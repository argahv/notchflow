import XCTest
@testable import NotchCore

final class ActionCatalogTests: XCTestCase {
    func testEveryContentActionsImpactAgreesWithTheEffectItShows() {
        for action in ContentAction.allCases {
            let descriptor = ActionCatalog.descriptor(for: action)
            XCTAssertEqual(descriptor.impact == .createsFile, action.effect == .createsFile, action.rawValue)
            XCTAssertEqual(descriptor.impact == .network, action.effect == .network, action.rawValue)
            XCTAssertEqual(descriptor.title, action.title)
        }
    }

    func testEveryActionHasItsOwnIdentifier() {
        let content = ContentAction.allCases.map { ActionCatalog.descriptor(for: $0).id }
        XCTAssertEqual(Set(content).count, content.count)
        let suggested = ActionCatalog.suggestionSamples.map { ActionCatalog.descriptor(for: $0).id }
        XCTAssertEqual(Set(suggested).count, suggested.count)
        XCTAssertTrue(Set(content).isDisjoint(with: suggested))
    }

    func testWhateverMakesSomethingCanUndoItAndNothingIsDestructive() {
        for descriptor in ActionCatalog.all {
            XCTAssertNotEqual(descriptor.impact, .destructive, descriptor.id)
            if descriptor.impact == .createsFile { XCTAssertEqual(descriptor.undo, .removesCreated, descriptor.id) }
            if descriptor.impact == .writesClipboard, descriptor.id.hasPrefix("suggest.") { XCTAssertEqual(descriptor.undo, .restoresClipboard) }
        }
    }

    func testOnlyFetchTitleReachesTheNetwork() {
        XCTAssertEqual(ActionCatalog.all.filter { $0.impact == .network }.map(\.id), ["content.linkPreview"])
    }

    func testARemindersActionAsksForPermissionBeforeItRuns() {
        let remind = ActionCatalog.descriptor(for: .remind(title: "Call", due: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(ActionGuard.clearance(for: remind, granted: [], confirmed: false), .needsPermission([.reminders]))
        XCTAssertEqual(ActionGuard.clearance(for: remind, granted: [.reminders], confirmed: false), .run)
    }

    func testAnythingDestructiveIsConfirmedEvenIfItsDescriptorForgetsToSaySo() {
        let careless = ActionDescriptor(id: "x.delete", title: "Delete", inputs: [.file], impact: .destructive, requiresConfirmation: false)
        XCTAssertEqual(ActionGuard.clearance(for: careless, granted: [], confirmed: false), .needsConfirmation)
        XCTAssertEqual(ActionGuard.clearance(for: careless, granted: [], confirmed: true), .run)
        let missing = ActionDescriptor(id: "x.both", title: "Both", inputs: [.file], permissions: [.filesAndFolders], impact: .destructive)
        XCTAssertEqual(ActionGuard.clearance(for: missing, granted: [], confirmed: true), .needsPermission([.filesAndFolders]),
                       "Permission comes first, so nothing is confirmed that then can't run")
    }

    func testImpactIsOrderedFromHarmlessToIrreversible() {
        XCTAssertLessThan(ActionImpact.readsOnly, .opensElsewhere)
        XCTAssertLessThan(ActionImpact.createsRecord, .network)
        XCTAssertEqual(ActionImpact.destructive, [ActionImpact.readsOnly, .destructive, .createsFile].max())
    }
}

final class SurfaceArbiterTests: XCTestCase {
    func testNothingTakesTheSurfaceFromThePerson() {
        // A download finishing, a timer ending or a failure arriving while a file is dragged or a note typed.
        for tier in SurfaceTier.allCases {
            XCTAssertEqual(SurfaceArbiter.admit(tier, into: SurfaceOccupancy(interacting: true)), .wait, tier.title)
        }
    }

    func testAFreeSurfaceAdmitsAnything() {
        for tier in SurfaceTier.allCases { XCTAssertEqual(SurfaceArbiter.admit(tier, into: SurfaceOccupancy()), .show) }
    }

    func testOnlyCriticalWorkPreemptsAnotherGlance() {
        let suggestion = SurfaceOccupancy(showing: .suggestion)
        XCTAssertEqual(SurfaceArbiter.admit(.critical, into: suggestion), .show)
        XCTAssertEqual(SurfaceArbiter.admit(.progress, into: suggestion), .wait)
        XCTAssertEqual(SurfaceArbiter.admit(.suggestion, into: suggestion), .wait, "A new suggestion waits for the current one")
        XCTAssertEqual(SurfaceArbiter.admit(.passive, into: suggestion), .wait)
        XCTAssertEqual(SurfaceArbiter.admit(.suggestion, into: SurfaceOccupancy(showing: .passive)), .wait, "Suggestions never preempt")
        XCTAssertEqual(SurfaceArbiter.admit(.critical, into: SurfaceOccupancy(showing: .critical)), .wait, "Alerts queue behind alerts")
    }

    func testActivityPrioritiesMapOntoTheTiers() {
        XCTAssertEqual(AttentionPriority.critical.surfaceTier, .critical)
        XCTAssertEqual(AttentionPriority.actionRequired.surfaceTier, .critical)
        XCTAssertEqual(AttentionPriority.background.surfaceTier, .progress)
        XCTAssertEqual(AttentionPriority.informational.surfaceTier, .passive)
        XCTAssertEqual(SurfaceArbiter.lowestPriorityAdmitted(over: .suggestion), .actionRequired)
        XCTAssertEqual(SurfaceArbiter.lowestPriorityAdmitted(over: nil), .silent)
    }

    func testPassiveNewsWaitsBehindASuggestionButWorkThatNeedsYouTakesTheSurface() {
        let arrived = Date(timeIntervalSince1970: 1_000)
        let behindSuggestion = AttentionContext(holdBelow: SurfaceArbiter.lowestPriorityAdmitted(over: .suggestion))
        var center = AttentionCenter()
        let done = AttentionItem(id: "build", priority: .informational, arrived: arrived)
        XCTAssertEqual(center.receive(done, context: behindSuggestion), .indicate)
        XCTAssertNil(center.resume(now: arrived.addingTimeInterval(5), context: behindSuggestion), "Still behind the suggestion")
        let input = AttentionItem(id: "agent", priority: .actionRequired, arrived: arrived.addingTimeInterval(6))
        XCTAssertEqual(center.receive(input, context: behindSuggestion), .present(input))
        XCTAssertEqual(center.dismissCurrent(now: arrived.addingTimeInterval(20), context: AttentionContext())?.id, "build",
                       "Once the surface is free the finished build is shown")
    }
}

final class PrivacyCatalogTests: XCTestCase {
    func testEveryContextSourceIsDescribed() {
        let covered = PrivacyCatalog.entries.reduce(into: Set<ContextSource>()) { $0.formUnion($1.sources) }
        XCTAssertEqual(covered, Set(ContextSource.allCases))
    }

    func testOnlyGitHubAndFetchTitleSendAnythingOffTheMac() {
        XCTAssertEqual(Set(PrivacyCatalog.entries.filter { $0.leavesMac != nil }.map(\.id)), ["github", "linkTitle"])
    }

    func testEveryEntrySaysHowToStopItAndClearIt() {
        XCTAssertEqual(Set(PrivacyCatalog.entries.map(\.id)).count, PrivacyCatalog.entries.count)
        for entry in PrivacyCatalog.entries {
            XCTAssertFalse(entry.turnOff.isEmpty, entry.id)
            XCTAssertFalse(entry.clear.isEmpty, entry.id)
            XCTAssertFalse(entry.storage.isEmpty, entry.id)
        }
    }

    func testAnythingThatReadsWhatYouCopyIsOffUntilYouTurnItOn() {
        for entry in PrivacyCatalog.entries where entry.sources.contains(.clipboard) { XCTAssertFalse(entry.onByDefault, entry.id) }
    }
}
