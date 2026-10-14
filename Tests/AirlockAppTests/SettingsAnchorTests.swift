import XCTest
import AirlockCore
@testable import AirlockApp

@MainActor
final class SettingsAnchorTests: XCTestCase {
    /// The card's own examples.
    func testTheCardsExamplesFindTheirSettings() {
        XCTAssertTrue(SettingsAnchor.search("sleep", guideOn: false).contains(.keepAwakeScreen))
        XCTAssertTrue(SettingsAnchor.search("shortcut", guideOn: false).contains(.clipboardShortcut))
        XCTAssertTrue(SettingsAnchor.search("shortcut", guideOn: false).contains(.keepAwakeShortcut))
        XCTAssertEqual(SettingsAnchor.search("history", guideOn: false).first, .clipboardHistory)
    }

    /// The guide's rows are not offered while the guide is off: they would
    /// land on a page the sidebar does not have.
    func testGuideRowsOnlyWithTheGuideOn() {
        XCTAssertFalse(SettingsAnchor.search("never look", guideOn: false).contains(.neverLook))
        XCTAssertTrue(SettingsAnchor.search("never look", guideOn: true).contains(.neverLook))
    }

    /// With the guide on, the agent rows are behind Developer mode, and a
    /// search must not offer a row the page is hiding.
    func testAgentRowsWaitBehindDeveloperMode() {
        XCTAssertFalse(SettingsAnchor.search("sound", guideOn: true, agentsOn: false).contains(.promptSound))
        XCTAssertTrue(SettingsAnchor.search("sound", guideOn: true, agentsOn: true).contains(.promptSound))
        XCTAssertTrue(SettingsAnchor.search("sound", guideOn: false, agentsOn: false).contains(.promptSound))
        XCTAssertTrue(SettingsAnchor.search("developer", guideOn: true, agentsOn: false).contains(.developerMode))
        XCTAssertFalse(SettingsAnchor.search("limit", guideOn: true, agentsOn: false).contains(.usageWarning))
        XCTAssertTrue(SettingsAnchor.search("limit", guideOn: false).contains(.usageWarning))
    }

    /// The call languages show on the Voice page only while call notes are on,
    /// and search follows the page.
    func testCallLanguagesOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("calls", guideOn: false, callNotesOn: false).contains(.callLanguages))
        XCTAssertEqual(SettingsAnchor.search("language on calls", guideOn: false, callNotesOn: true).first,
                       .callLanguages)
        XCTAssertEqual(SettingsAnchor.callLanguages.pane, .voice)
    }

    /// The call notes switch itself is there on or off: off, it is the only
    /// way back.
    func testTheCallNotesSwitchIsAlwaysThere() {
        XCTAssertEqual(SettingsAnchor.search("call notes", guideOn: false, callNotesOn: false).first, .callNotes)
        XCTAssertEqual(SettingsAnchor.search("call notes", guideOn: false, callNotesOn: true).first, .callNotes)
        XCTAssertEqual(SettingsAnchor.callNotes.pane, .voice)
    }

    /// The way to past calls shows beside the call languages, so it follows
    /// the same switch.
    func testPastCallsOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("past calls", guideOn: false, callNotesOn: false).contains(.pastCalls))
        XCTAssertEqual(SettingsAnchor.search("past calls", guideOn: false, callNotesOn: true).first, .pastCalls)
        XCTAssertEqual(SettingsAnchor.pastCalls.pane, .voice)
    }

    /// The words meetings spell their way sit with the other call rows.
    func testWordsToKnowOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("words to know", guideOn: false, callNotesOn: false)
            .contains(.knownWords))
        XCTAssertEqual(SettingsAnchor.search("words to know", guideOn: false, callNotesOn: true).first, .knownWords)
        XCTAssertEqual(SettingsAnchor.search("spelling", guideOn: false, callNotesOn: true).first, .knownWords)
        XCTAssertEqual(SettingsAnchor.knownWords.pane, .voice)
    }

    /// "Write notes online" sits with the other call rows, and only while
    /// notes online are switched on by hand for a subscriber.
    func testNotesOnlineOnlyWhileCallNotesAndNotesOnlineAreOn() {
        XCTAssertFalse(SettingsAnchor.search("notes online", guideOn: false, callNotesOn: true, notesOnlineOn: false)
            .contains(.notesOnline))
        XCTAssertFalse(SettingsAnchor.search("notes online", guideOn: false, callNotesOn: false, notesOnlineOn: true)
            .contains(.notesOnline))
        XCTAssertEqual(SettingsAnchor.search("write notes online", guideOn: false, callNotesOn: true,
                                             notesOnlineOn: true).first, .notesOnline)
        XCTAssertTrue(SettingsAnchor.search("gemini", guideOn: false, callNotesOn: true, notesOnlineOn: true)
            .contains(.notesOnline))
        XCTAssertEqual(SettingsAnchor.notesOnline.pane, .voice)
    }

    /// Every row a search can return lands on a page the sidebar offers.
    func testEveryAnchorLandsOnASidebarPage() {
        for guideOn in [false, true] {
            let pages = SettingsPane.sidebar(guideOn: guideOn)
            for anchor in SettingsAnchor.allCases where anchor.isAvailable(guideOn: guideOn) {
                XCTAssertTrue(pages.contains(anchor.pane), "\(anchor) → \(anchor.pane), guide \(guideOn)")
            }
        }
    }

    /// A row with no words to find it by is a row search cannot reach.
    func testEveryAnchorHasKeywords() {
        for anchor in SettingsAnchor.allCases {
            XCTAssertFalse(anchor.keywords.isEmpty, "\(anchor)")
        }
    }

    /// A free Airlock has no Licence page, and search cannot lead to one.
    func testAFreeAirlockHasNoLicencePage() {
        for guideOn in [false, true] {
            XCTAssertFalse(SettingsPane.sidebar(guideOn: guideOn, free: true).contains(.license))
            XCTAssertTrue(SettingsPane.sidebar(guideOn: guideOn, free: false).contains(.license))
        }
        XCTAssertEqual(SettingsAnchor.search("licence").contains(.licenceKey), !Pricing.isFree)
        XCTAssertEqual(SettingsPane.license.resolved, Pricing.isFree ? .general : .license)
    }
}
