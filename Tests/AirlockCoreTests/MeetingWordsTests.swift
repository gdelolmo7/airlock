import XCTest
@testable import AirlockCore

/// Every line of a call passes through `kept`, so most of these are about
/// leaving real speech alone. The lowercase lines are what Apple's recogniser
/// wrote for sentences whose first word was clipped.
final class MeetingWordsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let spanish = Locale(identifier: "es_ES")

    // MARK: - Invented phrases

    func testStockPhrasesAreDroppedInEnglishAndSpanish() {
        for line in ["Thanks for watching!", "Thank you for watching.", "Please subscribe to my channel.",
                     "Don't forget to like and subscribe!", "Gracias por ver el video.",
                     "¡Gracias por ver el vídeo!", "¡Suscríbete!", "No olvides suscribirte al canal."] {
            XCTAssertNil(MeetingWords.kept(line, in: english), line)
        }
    }

    /// The recogniser writes two of them as one line.
    func testALineMadeOnlyOfStockPhrasesIsDropped() {
        XCTAssertNil(MeetingWords.kept("Gracias por ver el vídeo. Suscríbete al canal.", in: spanish))
        XCTAssertNil(MeetingWords.kept(" Thanks for watching. Please subscribe.", in: english))
    }

    func testSubtitlingCreditsAreDropped() {
        for line in ["Subtitles by the Amara.org community",
                     "Subtítulos realizados por la comunidad de Amara.org",
                     "Sous-titres réalisés par la communauté d'Amara.org",
                     "Untertitel im Auftrag des ZDF, 2021"] {
            XCTAssertNil(MeetingWords.kept(line, in: english), line)
        }
    }

    /// Never cut out of real speech: the words are only dropped when they
    /// are the whole of what was said.
    func testTheSameWordsInsideRealSpeechAreKept() {
        let lines = ["Thanks for watching the demo, any questions before we move on?",
                     "We should ask people to subscribe to the newsletter.",
                     "Gracias por ver el vídeo. Lo comentamos el lunes.",
                     "Amara.org did the subtitles for our launch video last year, and the community was great."]
        for line in lines {
            XCTAssertEqual(MeetingWords.kept(line, in: english), line)
        }
    }

    /// What people really do say at the end of a call.
    func testOrdinaryGoodbyesAreKept() {
        for line in ["Thank you.", "See you next time.", "Thanks for listening.", "Gracias.", "Hasta luego."] {
            XCTAssertEqual(MeetingWords.kept(line, in: english), line)
        }
    }

    func testALineWithNoWordsIsDropped() {
        XCTAssertNil(MeetingWords.kept("  …  ", in: english))
        XCTAssertNil(MeetingWords.kept("♪", in: english))
        XCTAssertNil(MeetingWords.kept("", in: english))
    }

    // MARK: - Repeats

    func testARunOfOneWordIsKeptOnceWithItsLastPunctuation() {
        XCTAssertEqual(MeetingWords.kept("No, no, no, no, no.", in: english), "No.")
        XCTAssertEqual(MeetingWords.kept("Okay, okay, okay, okay. Let's start.", in: english), "Okay. Let's start.")
    }

    func testARunOfSeveralWordsIsKeptOnce() {
        XCTAssertEqual(MeetingWords.kept("Thank you, thank you, thank you.", in: english), "Thank you.")
        XCTAssertEqual(MeetingWords.collapsingRepeats("I'm going to I'm going to I'm going to I'm going to fix it"),
                       "I'm going to fix it")
    }

    func testARunMidSentenceLeavesTheSentenceWhole() {
        XCTAssertEqual(MeetingWords.kept("I said no no no to the second offer.", in: english),
                       "I said no to the second offer.")
    }

    func testTwiceIsNotARun() {
        let line = "Yes, yes, that works. Very very good."
        XCTAssertEqual(MeetingWords.kept(line, in: english), line)
    }

    func testNumbersAreNeverCollapsed() {
        let line = "Call me on 5 5 5 1 2 3 4."
        XCTAssertEqual(MeetingWords.kept(line, in: english), line)
    }

    func testRepeatsAreFoundWhateverTheAccentsAndCase() {
        XCTAssertEqual(MeetingWords.collapsingRepeats("Qué, que, QUÉ pasa"), "Qué pasa")
    }

    // MARK: - Capitals

    func testAClippedFirstWordGetsItsCapitalBack() {
        XCTAssertEqual(MeetingWords.kept("app shipped on Tuesday, and macOS support comes next.", in: english),
                       "App shipped on Tuesday, and macOS support comes next.")
        XCTAssertEqual(MeetingWords.kept(" el presupuesto del próximo trimestre.", in: spanish),
                       "El presupuesto del próximo trimestre.")
        XCTAssertEqual(MeetingWords.kept("nueva aplicación del iPhone salió el martes.", in: spanish),
                       "Nueva aplicación del iPhone salió el martes.")
    }

    /// Seen in the check: the clipped line began with the product name.
    func testAWordWithItsOwnCapitalsIsLeftAlone() {
        XCTAssertEqual(MeetingWords.kept("iPhone app shipped on Tuesday.", in: english),
                       "iPhone app shipped on Tuesday.")
        XCTAssertEqual(MeetingWords.kept("we tried it. macOS is next. eBay later.", in: english),
                       "We tried it. macOS is next. eBay later.")
    }

    func testEachSentenceInsideALineGetsACapital() {
        XCTAssertEqual(MeetingWords.kept("we ship on friday. then we rest! ok? fine.", in: english),
                       "We ship on friday. Then we rest! Ok? Fine.")
    }

    func testSpanishOpeningMarksAreSkipped() {
        XCTAssertEqual(MeetingWords.kept("¿vienes mañana? ¡claro que sí!", in: spanish),
                       "¿Vienes mañana? ¡Claro que sí!")
    }

    func testNothingMidSentenceIsTouched() {
        let line = "We moved it to 9 a.m. tomorrow, apples, pears, etc. and 3.5 million users... maybe more."
        XCTAssertEqual(MeetingWords.kept(line, in: english), line)
    }

    func testAlreadyCorrectLinesAreUnchanged() {
        for line in ["Hello, everyone.", "Let's go over the budget for next quarter.",
                     "Bueno, el plan es sencillo, lo lanzamos el viernes, luego descansamos.",
                     "3 people joined late."] {
            XCTAssertEqual(MeetingWords.kept(line, in: english), line)
        }
    }

    func testLanguagesWithoutCapitalsAreLeftAsWritten() {
        XCTAssertEqual(MeetingWords.kept("zoomで会議を始めます。", in: Locale(identifier: "ja_JP")),
                       "zoomで会議を始めます。")
        XCTAssertEqual(MeetingWords.kept("mac 上的会议", in: Locale(identifier: "zh_CN")), "mac 上的会议")
    }

    /// The capital follows the language: a dotted capital I in Turkish.
    func testTheCapitalFollowsTheLanguage() {
        XCTAssertEqual(MeetingWords.capitalised("istanbul'da", in: Locale(identifier: "tr_TR")), "İstanbul'da")
    }
}
