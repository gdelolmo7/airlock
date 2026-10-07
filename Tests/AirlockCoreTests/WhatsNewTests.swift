import XCTest
@testable import AirlockCore

/// When the "what's new" card opens, and what Sparkle's window is given.
///
/// The failure that matters most is the card showing to someone who has seen
/// it: a note that keeps coming back is a nag, and the owner asked for it once.
final class WhatsNewTests: XCTestCase {
    private let catalog = [
        WhatsNew.Notes(version: "1.0.18", title: "New", items: [WhatsNew.Item("star", "One")]),
    ]

    private func decide(_ version: String, seen: String?, firstRun: Bool = false,
                        in catalog: [WhatsNew.Notes]? = nil) -> WhatsNew.Decision {
        WhatsNew.decide(version: version, lastSeen: seen, isFirstRun: firstRun, catalog: catalog ?? self.catalog)
    }

    private func shown(_ decision: WhatsNew.Decision) -> WhatsNew.Card? {
        if case .show(let card) = decision { return card }
        return nil
    }

    private func notes(_ version: String, _ lines: Int) -> WhatsNew.Notes {
        WhatsNew.Notes(version: version, title: "Title \(version)",
                       items: (1...lines).map { WhatsNew.Item("star", "\(version) line \($0)") })
    }

    func testAnUpdateWithNotesShowsThem() {
        let card = shown(decide("1.0.18", seen: "1.0.17"))
        XCTAssertEqual(card?.label, "new in 1.0.18")
        XCTAssertEqual(card?.title, "New")
        XCTAssertEqual(card?.items.map(\.text), ["One"])
        XCTAssertEqual(card?.version, "1.0.18")
        XCTAssertEqual(card?.moreCount, 0)
    }

    /// Every install from before the card existed has nothing recorded, and
    /// they are the people the first card is for.
    func testAnInstallThatNeverRecordedAVersionSeesTheCard() {
        XCTAssertNotNil(shown(decide("1.0.18", seen: nil)))
    }

    func testTheSameVersionNeverShowsTwice() {
        XCTAssertEqual(decide("1.0.18", seen: "1.0.18"), .nothing)
    }

    func testANewUserIsNotShownAListOfChanges() {
        XCTAssertEqual(decide("1.0.18", seen: nil, firstRun: true), .remember)
        XCTAssertEqual(decide("1.0.18", seen: "1.0.18", firstRun: true), .nothing)
    }

    func testAVersionWithoutNotesIsRememberedQuietly() {
        XCTAssertEqual(decide("1.0.19", seen: "1.0.18"), .remember)
    }

    /// Going back to an older copy is not news, and must not mark the older
    /// version as the one last seen.
    func testGoingBackToAnOlderVersionShowsNothing() {
        XCTAssertEqual(decide("1.0.18", seen: "1.0.20"), .nothing)
    }

    /// Numeric, not alphabetical: "1.0.9" sorts after "1.0.18" as text.
    func testVersionsCompareAsNumbers() {
        XCTAssertNotNil(shown(decide("1.0.18", seen: "1.0.9")))
    }

    func testABuildWithoutAVersionDoesNothing() {
        XCTAssertEqual(decide("", seen: nil), .nothing)
    }

    // MARK: - Two updates in a row

    /// The owner's question: 1.0.17 straight to 1.0.19 must not lose 1.0.18.
    func testASkippedVersionIsFoldedInNewestFirst() {
        let catalog = [notes("1.0.19", 1), notes("1.0.18", 2), notes("1.0.17", 1)]
        let card = shown(decide("1.0.19", seen: "1.0.17", in: catalog))
        XCTAssertEqual(card?.label, "new since 1.0.17")
        XCTAssertEqual(card?.title, WhatsNew.foldedTitle)
        XCTAssertEqual(card?.items.map(\.text), ["1.0.19 line 1", "1.0.18 line 1", "1.0.18 line 2"])
        XCTAssertEqual(card?.version, "1.0.19")
    }

    /// Order in the catalog is a convention, not something to rely on.
    func testFoldingSortsByVersionNotByCatalogOrder() {
        let catalog = [notes("1.0.9", 1), notes("1.0.10", 1)]
        let card = shown(decide("1.0.10", seen: "1.0.8", in: catalog))
        XCTAssertEqual(card?.items.map(\.text), ["1.0.10 line 1", "1.0.9 line 1"])
    }

    func testAFoldedCardKeepsFourLinesAndCountsTheRest() {
        let catalog = [notes("1.0.20", 3), notes("1.0.19", 2), notes("1.0.18", 1)]
        let card = shown(decide("1.0.20", seen: "1.0.17", in: catalog))
        XCTAssertEqual(card?.items.count, WhatsNew.maxItems)
        XCTAssertEqual(card?.items.first?.text, "1.0.20 line 1")
        XCTAssertEqual(card?.moreCount, 2)
    }

    /// A card quit before it was read: its notes come back with the next one.
    func testAnUnreadCardComesBackWithTheNextVersionWithoutNotes() {
        let catalog = [notes("1.0.18", 2)]
        let card = shown(decide("1.0.19", seen: "1.0.17", in: catalog))
        XCTAssertEqual(card?.label, "new in 1.0.18")
        XCTAssertEqual(card?.items.count, 2)
        XCTAssertEqual(card?.version, "1.0.19", "the running version is the one written down")
    }

    /// An entry written ahead of a release describes something this copy
    /// does not have.
    func testNotesForANewerVersionThanTheRunningOneAreNotShown() {
        let catalog = [notes("1.0.19", 1), notes("1.0.18", 1)]
        let card = shown(decide("1.0.18", seen: "1.0.17", in: catalog))
        XCTAssertEqual(card?.items.map(\.text), ["1.0.18 line 1"])
    }

    func testNothingSeenYetFoldsEverythingUpToTheRunningVersion() {
        let catalog = [notes("1.0.19", 1), notes("1.0.18", 1)]
        let card = shown(decide("1.0.19", seen: nil, in: catalog))
        XCTAssertEqual(card?.label, "new in 1.0.19")
        XCTAssertEqual(card?.items.count, 2)
    }

    /// The card has no scroll view, and the release script cannot ship an
    /// empty or overlong note without someone noticing here first.
    func testEveryShippedNoteFitsTheCard() {
        XCTAssertFalse(WhatsNew.catalog.isEmpty)
        for notes in WhatsNew.catalog {
            XCTAssertFalse(notes.title.isEmpty, notes.version)
            XCTAssertTrue((1...4).contains(notes.items.count), notes.version)
            for item in notes.items {
                XCTAssertFalse(item.symbol.isEmpty, notes.version)
                XCTAssertLessThanOrEqual(item.text.count, 100, "\(notes.version): \(item.text)")
            }
        }
        XCTAssertEqual(Set(WhatsNew.catalog.map(\.version)).count, WhatsNew.catalog.count,
                       "two entries for one version")
    }

    /// `generate_appcast` embeds a fragment only when it has no DOCTYPE or
    /// body tags; with them it links to the file instead.
    func testHTMLIsAnEmbeddableFragment() {
        let notes = WhatsNew.Notes(version: "1.0.18", title: "Calls & <logos>",
                                   items: [WhatsNew.Item("phone", "A & B")])
        let html = WhatsNew.html(notes)
        XCTAssertFalse(html.localizedCaseInsensitiveContains("<!doctype"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("<body"))
        XCTAssertTrue(html.contains("<h3>Calls &amp; &lt;logos&gt;</h3>"))
        XCTAssertTrue(html.contains("<li>A &amp; B</li>"))
    }
}
