import XCTest
@testable import AirlockCore

final class SettingsSearchTests: XCTestCase {
    private func score(_ query: String, title: String = "Let the screen turn off",
                       keywords: [String] = ["keep awake", "sleep", "display"],
                       page: String = "Notch") -> Int? {
        SettingsSearch.score(query: query, title: title, keywords: keywords, page: page)
    }

    /// The card's own examples: "sleep" has to find keep-awake.
    func testAKeywordFindsTheSetting() {
        XCTAssertNotNil(score("sleep"))
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertNil(score(""))
        XCTAssertNil(score("   "))
    }

    func testCaseAndAccentsDoNotMatter() {
        XCTAssertNotNil(score("SCREEN"))
        XCTAssertNotNil(score("écran", title: "Écran"))
    }

    /// Words start a match; the middle of a word does not.
    func testAWordMatchesFromItsStart() {
        XCTAssertNotNil(score("short", title: "Keyboard shortcut"))
        XCTAssertNil(score("cut", title: "Keyboard shortcut", keywords: []))
    }

    /// Every word must be found somewhere, so a second word narrows.
    func testEveryWordHasToMatch() {
        XCTAssertNotNil(score("screen sleep"))
        XCTAssertNil(score("screen clipboard"))
    }

    /// The title outranks a keyword, which outranks the page name.
    func testTitleMatchesRankFirst() {
        let inTitle = score("screen")!
        let inKeyword = score("display")!
        let inPage = score("notch")!
        XCTAssertGreaterThan(inTitle, inKeyword)
        XCTAssertGreaterThan(inKeyword, inPage)
    }

    func testTheTitlesFirstWordRanksHighest() {
        XCTAssertGreaterThan(score("let")!, score("screen")!)
    }
}
