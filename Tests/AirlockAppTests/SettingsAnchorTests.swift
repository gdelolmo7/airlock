import XCTest
import AirlockCore
@testable import AirlockApp

@MainActor
final class SettingsAnchorTests: XCTestCase {
    /// The card's own examples.
    func testTheCardsExamplesFindTheirSettings() {
        XCTAssertTrue(SettingsAnchor.search("sleep").contains(.keepAwakeScreen))
        XCTAssertTrue(SettingsAnchor.search("shortcut").contains(.clipboardShortcut))
        XCTAssertTrue(SettingsAnchor.search("shortcut").contains(.keepAwakeShortcut))
        XCTAssertEqual(SettingsAnchor.search("history").first, .clipboardHistory)
    }

    /// The call languages show on the Voice page only while call notes are on,
    /// and search follows the page.
    func testCallLanguagesOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("calls", callNotesOn: false).contains(.callLanguages))
        XCTAssertEqual(SettingsAnchor.search("language on calls", callNotesOn: true).first,
                       .callLanguages)
        XCTAssertEqual(SettingsAnchor.callLanguages.pane, .voice)
    }

    /// The call notes switch itself is there on or off: off, it is the only
    /// way back.
    func testTheCallNotesSwitchIsAlwaysThere() {
        XCTAssertEqual(SettingsAnchor.search("call notes", callNotesOn: false).first, .callNotes)
        XCTAssertEqual(SettingsAnchor.search("call notes", callNotesOn: true).first, .callNotes)
        XCTAssertEqual(SettingsAnchor.callNotes.pane, .voice)
    }

    /// The way to past calls shows beside the call languages, so it follows
    /// the same switch.
    func testPastCallsOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("past calls", callNotesOn: false).contains(.pastCalls))
        XCTAssertEqual(SettingsAnchor.search("past calls", callNotesOn: true).first, .pastCalls)
        XCTAssertEqual(SettingsAnchor.pastCalls.pane, .voice)
    }

    /// The words meetings spell their way sit with the other call rows.
    func testWordsToKnowOnlyWhileCallNotesAreOn() {
        XCTAssertFalse(SettingsAnchor.search("words to know", callNotesOn: false)
            .contains(.knownWords))
        XCTAssertEqual(SettingsAnchor.search("words to know", callNotesOn: true).first, .knownWords)
        XCTAssertEqual(SettingsAnchor.search("spelling", callNotesOn: true).first, .knownWords)
        XCTAssertEqual(SettingsAnchor.knownWords.pane, .voice)
    }

    /// "Write notes online" sits with the other call rows, and only while
    /// notes online are switched on by hand for a subscriber.
    func testNotesOnlineOnlyWhileCallNotesAndNotesOnlineAreOn() {
        XCTAssertFalse(SettingsAnchor.search("notes online", callNotesOn: true, notesOnlineOn: false)
            .contains(.notesOnline))
        XCTAssertFalse(SettingsAnchor.search("notes online", callNotesOn: false, notesOnlineOn: true)
            .contains(.notesOnline))
        XCTAssertEqual(SettingsAnchor.search("write notes online", callNotesOn: true,
                                             notesOnlineOn: true).first, .notesOnline)
        XCTAssertTrue(SettingsAnchor.search("gemini", callNotesOn: true, notesOnlineOn: true)
            .contains(.notesOnline))
        XCTAssertEqual(SettingsAnchor.notesOnline.pane, .voice)
    }

    /// Every row a search can return lands on a page the sidebar offers.
    func testEveryAnchorLandsOnASidebarPage() {
        for anchor in SettingsAnchor.allCases where anchor.isAvailable() {
            XCTAssertTrue(SettingsPane.sidebarCases.contains(anchor.pane), "\(anchor) → \(anchor.pane)")
        }
    }

    /// A row with no words to find it by is a row search cannot reach.
    func testEveryAnchorHasKeywords() {
        for anchor in SettingsAnchor.allCases {
            XCTAssertFalse(anchor.keywords.isEmpty, "\(anchor)")
        }
    }

    /// Someone typing in Spanish finds the same rows, whatever language the
    /// app is in (the tests see English titles), and an accent left off or
    /// added changes nothing. The language row alone carries its own.
    func testSpanishWordsFindTheirRows() {
        for anchor in SettingsAnchor.allCases where anchor != .appLanguage {
            XCTAssertFalse(anchor.spanishKeywords.isEmpty, "\(anchor)")
        }
        XCTAssertTrue(SettingsAnchor.search("portapapeles").contains(.clipboardHistory))
        XCTAssertTrue(SettingsAnchor.search("micrófono").contains(.microphoneInput))
        XCTAssertTrue(SettingsAnchor.search("microfono").contains(.microphoneInput))
        XCTAssertTrue(SettingsAnchor.search("suscripción").contains(.plans))
        XCTAssertTrue(SettingsAnchor.search("bateria").contains(.batteryPercentage))
        XCTAssertTrue(SettingsAnchor.search("transcripcion", callNotesOn: true).contains(.callNotes))
        XCTAssertTrue(SettingsAnchor.search("dictado").contains(.holdToDictate))
    }

    /// Every copy has a Plans page, Free included: it is where a key goes
    /// and where Plus and Pro are bought, and search leads to it by the words
    /// people use for either.
    func testEveryCopyHasAPlansPage() {
        XCTAssertTrue(SettingsPane.sidebarCases.contains(.license))
        XCTAssertEqual(SettingsPane.license.title, "Plans")
        XCTAssertTrue(SettingsAnchor.search("licence").contains(.licenceKey))
        XCTAssertEqual(SettingsAnchor.search("upgrade").first, .plans)
        XCTAssertEqual(SettingsAnchor.search("pro").first, .plans)
        XCTAssertTrue(SettingsAnchor.search("check my plan").contains(.checkPlan))
        XCTAssertEqual(SettingsPane.license.resolved, .license)
    }
}
