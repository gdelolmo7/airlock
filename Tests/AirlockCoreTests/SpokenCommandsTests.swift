import XCTest
@testable import AirlockCore

final class SpokenCommandsTests: XCTestCase {
    private func said(_ text: String, _ languages: [String] = ["en"],
                      saved: [SavedText] = [], switches: SpokenCommands.Switches = .init()) -> SpokenCommands.Outcome {
        SpokenCommands.apply(text, switches: switches, saved: saved, languages: languages)
    }

    // MARK: Punctuation

    func testCommaAndFullStop() {
        XCTAssertEqual(said("Hello comma how are you full stop").text, "Hello, how are you.")
    }

    func testTheRecognisersOwnSignGivesWay() {
        XCTAssertEqual(said("Hello. Comma, how are you").text, "Hello, how are you")
    }

    func testQuestionAndExclamation() {
        XCTAssertEqual(said("are you coming question mark great exclamation mark").text,
                       "are you coming? Great!")
    }

    func testNewLineAndParagraph() {
        XCTAssertEqual(said("Dear team new paragraph the build is green. New line Thanks").text,
                       "Dear team\n\nThe build is green.\nThanks")
    }

    func testAWordAfterADeterminerIsLeftAlone() {
        XCTAssertEqual(said("put the comma after the name").text, "put the comma after the name")
        XCTAssertEqual(said("we launched a new line of shoes").text, "we launched a new line of shoes")
        XCTAssertEqual(said("it came to a full stop").text, "it came to a full stop")
    }

    func testWholeWordsOnly() {
        XCTAssertEqual(said("the commander arrived").text, "the commander arrived")
        XCTAssertEqual(said("commas everywhere").text, "commas everywhere")
    }

    func testSpanish() {
        XCTAssertEqual(said("Hola coma qué tal punto nos vemos", ["es-ES"]).text, "Hola, qué tal. Nos vemos")
        XCTAssertEqual(said("Primero punto y aparte segundo", ["es"]).text, "Primero.\nSegundo")
        XCTAssertEqual(said("una cosa nueva linea otra", ["es"]).text, "una cosa\nOtra")
        XCTAssertEqual(said("uno punto y coma dos", ["es"]).text, "uno; dos")
    }

    func testSpanishPuntoAsAWordStays() {
        XCTAssertEqual(said("desde mi punto de vista", ["es"]).text, "desde mi punto de vista")
        XCTAssertEqual(said("a las tres en punto", ["es"]).text, "a las tres en punto")
    }

    func testOnlyTheDictationLanguage() {
        XCTAssertEqual(said("a coma patient", ["en"]).text, "a coma patient")
        XCTAssertEqual(said("comma", ["es"]).text, "comma")
    }

    func testSwitchedOff() {
        XCTAssertEqual(said("Hello comma world", switches: .init(punctuation: false)).text, "Hello comma world")
    }

    // MARK: Scratch that

    func testScratchThatDropsTheSentenceBefore() {
        XCTAssertEqual(said("I want pizza. Scratch that. I want pasta.").text, "I want pasta.")
        XCTAssertEqual(said("Hello there. I want pizza. Scratch that, I want pasta.").text,
                       "Hello there. I want pasta.")
    }

    func testScratchThatAfterASpokenFullStop() {
        XCTAssertEqual(said("Hi full stop I want pizza full stop scratch that I want pasta").text,
                       "Hi. I want pasta")
    }

    func testScratchThatFirstTakesBackTheLastDictation() {
        let outcome = said("Scratch that. Send it tomorrow.")
        XCTAssertTrue(outcome.erasePrevious)
        XCTAssertEqual(outcome.text, "Send it tomorrow.")
        let alone = said("Scratch that.")
        XCTAssertTrue(alone.erasePrevious)
        XCTAssertEqual(alone.text, "")
    }

    func testScratchThatInTheMiddleDoesNotReachBack() {
        XCTAssertFalse(said("I want pizza scratch that").erasePrevious)
        XCTAssertEqual(said("I want pizza scratch that").text, "")
    }

    func testScratchThatAsAVerbStays() {
        XCTAssertEqual(said("please don't scratch that table").text, "please don't scratch that table")
    }

    func testBorraEso() {
        XCTAssertEqual(said("Quiero pizza. Borra eso. Quiero pasta.", ["es"]).text, "Quiero pasta.")
    }

    func testScratchSwitchedOff() {
        let outcome = said("Scratch that.", switches: .init(scratch: false))
        XCTAssertFalse(outcome.erasePrevious)
        XCTAssertEqual(outcome.text, "Scratch that.")
    }

    // MARK: Saved texts

    private let address = SavedText(name: "my address", text: "Calle Mayor 1\n28013 Madrid")

    func testTheWholeDictationTypesTheSavedText() {
        let outcome = said("My address.", saved: [address])
        XCTAssertTrue(outcome.isSavedText)
        XCTAssertEqual(outcome.text, "Calle Mayor 1\n28013 Madrid")
    }

    func testANameInsideASentenceIsJustWords() {
        let outcome = said("send it to my address please", saved: [address])
        XCTAssertFalse(outcome.isSavedText)
        XCTAssertEqual(outcome.text, "send it to my address please")
    }

    func testSavedTextNamesIgnoreCaseAndAccents() {
        let firma = SavedText(name: "Mi firma", text: "Un saludo, Guille")
        XCTAssertEqual(said("mi FIRMA", ["es"], saved: [firma]).text, "Un saludo, Guille")
    }

    func testSavedTextsSwitchedOff() {
        XCTAssertFalse(said("my address", saved: [address], switches: .init(savedTexts: false)).isSavedText)
    }

    func testAddingReplacesTheSameName() {
        var list = SavedText.adding(name: "sign off", text: "Best", to: [])
        list = SavedText.adding(name: "Sign  Off", text: "Cheers", to: list)
        XCTAssertEqual(list.map(\.text), ["Cheers"])
        XCTAssertEqual(SavedText.adding(name: "  ", text: "x", to: list), list)
        XCTAssertEqual(SavedText.adding(name: "x", text: " \n", to: list), list)
    }
}
