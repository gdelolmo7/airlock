import XCTest
@testable import AirlockCore

/// "Words to know" as dictation reads it, and learning a word from a fix.
/// Names here are made up.
final class DictationWordsTests: XCTestCase {
    private let dictionary: Set<String> = ["the", "cursor", "move", "there", "their", "send", "it", "to",
                                           "please", "codex", "call", "with", "tomorrow", "meet"]
    private func isWord(_ word: String) -> Bool { dictionary.contains(word) }

    // MARK: - Spelling

    func testTypedWordsAndBuiltInsAreSpelled() {
        let words = DictationWords(typed: ["Brightwell"])
        XCTAssertEqual(words.respelled("open bright well in x code", isDictionaryWord: isWord),
                       "open Brightwell in Xcode")
    }

    func testADictionaryWordIsSparedAlone() {
        let words = DictationWords(typed: [])
        XCTAssertEqual(words.respelled("move the cursor there", isDictionaryWord: isWord),
                       "move the cursor there", "the app Cursor must not take the word")
    }

    func testARemovedBuiltInIsNotSpelled() {
        let words = DictationWords(typed: [], builtInsRemoved: ["Xcode"])
        XCTAssertEqual(words.respelled("open x code", isDictionaryWord: isWord), "open x code")
        XCTAssertFalse(words.spellings.contains("Xcode"))
        XCTAssertTrue(words.spellings.contains("Claude"))
    }

    func testAlwaysWriteWinsEvenForShortAndDictionaryWords() {
        let words = DictationWords(typed: [], replacements: [.init(heard: "meet", written: "Mitt"),
                                                             .init(heard: "jon", written: "Jon")])
        XCTAssertEqual(words.respelled("meet jon tomorrow", isDictionaryWord: isWord), "Mitt Jon tomorrow")
    }

    func testNewLinesStay() {
        let words = DictationWords(typed: ["Brightwell"])
        XCTAssertEqual(words.respelled("bright well\nsecond line", isDictionaryWord: isWord),
                       "Brightwell\nsecond line")
    }

    func testRecogniserHearsEverything() {
        let words = DictationWords(typed: ["Brightwell"], replacements: [.init(heard: "jon", written: "Jon")])
        XCTAssertEqual(Array(words.spellings.prefix(2)), ["Jon", "Brightwell"])
        XCTAssertTrue(words.spellings.contains("Airlock"))
    }

    func testCallsTakeTheAlwaysWriteEntriesToo() {
        let known = MeetingKnownWords(typed: [], replacements: [("jon", "Jon")])
        XCTAssertEqual(known.respelled("ask jon."), "ask Jon.")
    }

    // MARK: - The lists

    func testAlwaysWriteIsTypedWithAnArrow() {
        XCTAssertEqual(DictationWords.replacement(from: " jon -> Jon "), .init(heard: "jon", written: "Jon"))
        XCTAssertEqual(DictationWords.replacement(from: "bright well → Brightwell"),
                       .init(heard: "bright well", written: "Brightwell"))
        XCTAssertNil(DictationWords.replacement(from: "Brightwell"))
        XCTAssertNil(DictationWords.replacement(from: "-> Jon"))
    }

    func testAddingReplacesTheSameHeardWords() {
        var list = DictationWords.adding(.init(heard: "jon", written: "Jon"), to: [])
        list = DictationWords.adding(.init(heard: "Jon", written: "Jonh"), to: list)
        XCTAssertEqual(list, [.init(heard: "Jon", written: "Jonh")])
        XCTAssertEqual(DictationWords.adding(.init(heard: "Jon", written: "Jon"), to: []), [],
                       "writing a word as itself is no entry")
        XCTAssertEqual(DictationWords.removing(.init(heard: "jon", written: ""), from: list), [])
    }

    // MARK: - Learning from a fix

    private let words = DictationWords(typed: [])

    private func find(_ typed: String, _ before: String, _ after: String) -> DictationCorrection.Learned? {
        DictationCorrection.find(typed: typed, before: before, after: after, words: words, isDictionaryWord: isWord)
    }

    func testASpellingFixIsLearnedAsAlwaysWrite() {
        let typed = "send it to brightwel please"
        XCTAssertEqual(find(typed, "Hi, " + typed, "Hi, send it to Brightwell please"),
                       .init(word: "Brightwell", heard: "brightwel"))
    }

    func testACapitalOnlyFixIsLearnedAsAWord() {
        let typed = "call with velaroja tomorrow"
        XCTAssertEqual(find(typed, typed, "call with Velaroja tomorrow"), .init(word: "Velaroja", heard: nil))
    }

    func testPunctuationAroundTheWordIsFine() {
        let typed = "send it to brightwel."
        XCTAssertEqual(find(typed, typed, "send it to Brightwell."), .init(word: "Brightwell", heard: "brightwel"))
    }

    func testNothingChangedLearnsNothing() {
        XCTAssertNil(find("send it to brightwel", "send it to brightwel", "send it to brightwel"))
    }

    func testADictionaryWordIsNeverLearned() {
        let typed = "send it there please"
        XCTAssertNil(find(typed, typed, "send it their please"))
    }

    func testShortWordsAreNeverLearned() {
        let typed = "send it to jon please"
        XCTAssertNil(find(typed, typed, "send it to Jön please"), "three letters")
    }

    func testAWholeOtherWordIsAnEditNotAFix() {
        let typed = "send it to brightwel please"
        XCTAssertNil(find(typed, typed, "send it to Marguerite please"))
    }

    func testTwoWordsChangedLearnsNothing() {
        let typed = "send it to brightwel please"
        XCTAssertNil(find(typed, typed, "send it to Brightwell pleese"))
    }

    func testOneWordForTwoLearnsNothing() {
        let typed = "send it to bright well please"
        XCTAssertNil(find(typed, typed, "send it to Brightwell please"))
    }

    func testTooFewWordsLearnNothing() {
        XCTAssertNil(find("brightwel please", "brightwel please", "Brightwell please"))
    }

    func testAWordAlreadyKnownIsNotOfferedAgain() {
        let known = DictationWords(typed: ["Brightwell"])
        let typed = "send it to brightwel please"
        XCTAssertNil(DictationCorrection.find(typed: typed, before: typed, after: "send it to Brightwell please",
                                              words: known, isDictionaryWord: isWord))
    }

    func testDigitsAreNeverLearned() {
        let typed = "send it to brightwel please"
        XCTAssertNil(find(typed, typed, "send it to Brightw3l please"))
    }

    func testTextThatWasAlreadyThereIsNotAFix() {
        let typed = "send it to brightwel please"
        let before = "send it to Brightwell please. " + typed
        XCTAssertNil(find(typed, before, before + " "), "the near match was there before the dictation")
    }

    func testNearSpelling() {
        XCTAssertTrue(DictationCorrection.isNearSpelling("brightwel", "brightwell"))
        XCTAssertTrue(DictationCorrection.isNearSpelling("shavon", "siobhan") == false)
        XCTAssertEqual(DictationCorrection.distance(Array("kitten"), Array("sitting")), 3)
    }

    // MARK: - The notch line

    func testTheRememberCardHasOneButton() {
        let ask = DictationHoldNotice.rememberWord("Brightwell")
        XCTAssertEqual(ask.fix, .rememberWord)
        XCTAssertEqual(ask.tone, .note)
        XCTAssertEqual(ask.closesAfter, 10)
        XCTAssertTrue(ask.sentence.contains("Brightwell"))
        let told = DictationHoldNotice.rememberedWord("Brightwell")
        XCTAssertNil(told.fix)
        XCTAssertEqual(told.closesAfter, 4)
    }
}
