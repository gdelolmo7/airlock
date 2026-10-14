import XCTest
@testable import AirlockCore

/// Which questions are answered from the person's calls.
///
/// Both lists matter equally. A call question missed gets a general answer
/// that cannot know the call; a general question taken gets "nothing in your
/// calls" instead of the answer the model could have given.
final class CallQuestionTests: XCTestCase {
    private let names = ["Marta García", "Pablo", "Ana Ruiz"]

    private func assertTaken(_ phrases: [String], names: [String]? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertTrue(CallQuestion.isAboutPastCalls(phrase, names: names ?? self.names),
                          "\(phrase) is about a past call", file: file, line: line)
        }
    }

    private func assertLeft(_ phrases: [String], names: [String]? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertFalse(CallQuestion.isAboutPastCalls(phrase, names: names ?? self.names),
                           "\(phrase) is not about a past call", file: file, line: line)
        }
    }

    // MARK: - English, taken

    func testSomethingSaidBySomeoneOnACall() {
        assertTaken([
            "What did Marta say about the budget?",
            "did Marta mention the deadline?",
            "What did I tell Pablo yesterday?",
            "what did they say about pricing on the sync last week",
            "What did Ana share on the call?",
        ])
    }

    func testWhatWeAgreedNeedsNothingElse() {
        assertTaken([
            "what did we agree",
            "What did we decide about the launch?",
            "what was decided",
            "what did we all agree on",
        ], names: [])
    }

    func testACallPutInThePast() {
        assertTaken([
            "When is the launch, from Tuesday's meeting?",
            "who was on the call this morning?",
            "What happened in yesterday's stand-up?",
            "How long was the call with Pablo?",
            "what came out of the 1:1 last week",
            "summarize yesterday's call",
        ], names: [])
    }

    /// "they" or "I" can only be someone the person knows, so a day is
    /// enough. A stranger's name is not: that is the news.
    func testSomeoneTheyKnowOnADay() {
        assertTaken([
            "what did they say about pricing yesterday",
            "What did I promise on Monday?",
            "¿Qué me dijo ayer?",
            "¿qué dijeron ellos el lunes?",
        ], names: [])
        assertLeft(["What did Messi say yesterday?", "¿Qué dijo Messi ayer?"], names: [])
    }

    func testTheCallWithSomeone() {
        assertTaken(["what did we agree on the call with Pablo",
                     "Remind me what Pablo promised on Monday"])
    }

    // MARK: - Spanish, taken

    func testSpanishWithAndWithoutTheMarks() {
        assertTaken([
            "¿Qué quedamos ayer en la llamada con Pablo?",
            "qué quedamos ayer en la llamada con Pablo",
            "que quedamos con pablo",
            "en qué quedamos en la reunión del lunes",
            "¿De qué hablamos el martes?",
        ])
    }

    func testSpanishSomethingSaid() {
        assertTaken([
            "¿Qué dijo Marta del presupuesto?",
            "que dijo marta del presupuesto",
            "dijo Marta algo sobre el presupuesto",
            "¿Qué se decidió en la reunión de ayer?",
            "¿Qué hemos acordado con Pablo?",
            "recuérdame qué prometió Marta esta mañana",
        ])
    }

    func testSpanishCallPutInThePast() {
        assertTaken([
            "¿Quién estuvo en la llamada?",
            "¿Cuánto duró la reunión de esta mañana?",
            "resúmeme la llamada de ayer",
            "¿Qué salió de la reunión con Ana?",
        ], names: [])
    }

    func testAccentsAndCaseDoNotMatter() {
        assertTaken(["QUÉ DIJO MARTA DE LA REUNIÓN", "que dijo marta de la reunion"])
    }

    // MARK: - General questions, left alone

    func testGeneralQuestionsAreLeft() {
        assertLeft([
            "what's the weather",
            "How do I zip a folder?",
            "What's the weather tomorrow?",
            "what's the capital of France",
            "who won the match yesterday?",
            "how do you say yesterday in French",
            "What did Messi say yesterday after the match?",
            "¿Qué tiempo hace mañana?",
            "¿Qué hora es?",
            "¿Cómo se dice reunión en inglés?",
        ])
    }

    /// A name only counts when it is someone the calls were with.
    func testSomeoneNobodyCalledIsNotACall() {
        XCTAssertFalse(CallQuestion.isAboutPastCalls("What did Marta say about the budget?"))
        XCTAssertTrue(CallQuestion.isAboutPastCalls("What did Marta say about the budget?",
                                                    names: ["Marta"]))
    }

    /// Only "someone said" waits for the names; everything else is settled
    /// from the words alone, without reading a call.
    func testOnlySomeoneSaidWaitsForTheNames() {
        XCTAssertEqual(CallQuestion.verdict("What did Marta say about the budget?"), .ifNamed)
        XCTAssertEqual(CallQuestion.verdict("¿Qué dijo Marta del presupuesto?"), .ifNamed)
        XCTAssertEqual(CallQuestion.verdict("what did we agree"), .yes)
        XCTAssertEqual(CallQuestion.verdict("What did Marta say on the call?"), .yes)
        XCTAssertEqual(CallQuestion.verdict("How do I zip a folder?"), .no)
        XCTAssertEqual(CallQuestion.verdict("What's Marta's email?"), .no)
    }

    func testAKnownNameAloneIsNotACallQuestion() {
        assertLeft(["What's Marta's email?", "Where does Pablo live?", "¿Cuándo es el cumpleaños de Ana?"])
    }

    // MARK: - Calls, but not what was said

    func testUsingACallIsNotAskingAboutOne() {
        assertLeft([
            "How do I join the call?",
            "how do I share my screen on the call?",
            "how do I mute myself in the meeting",
            "What's the link for the meeting with Pablo?",
            "¿Cómo comparto pantalla en la llamada?",
            "¿Cómo me uno a la reunión?",
            "¿Cuál es el enlace de la reunión?",
        ])
    }

    func testCallsStillToComeAreTheCalendars() {
        assertLeft([
            "when is my next meeting?",
            "What time is the meeting with Pablo?",
            "what time is the meeting today",
            "When is the meeting on Tuesday?",
            "what should I prepare for the call with Ana",
            "¿Cuándo es la próxima reunión?",
            "¿A qué hora es la reunión de mañana?",
            "¿Quedamos mañana?",
            "¿Hablamos mañana con Pablo?",
        ])
    }

    func testTheWordAloneIsNotACall() {
        assertLeft([
            "What is a stand-up meeting?",
            "How many calls did I miss today?",
            "Can you call Pablo?",
            "¿Puedes llamar a Pablo?",
        ])
    }

    // MARK: - Agent work, left to the ladder

    func testInstructionsAreNotQuestions() {
        assertLeft([
            "fix the failing tests in the call notes module",
            "add a test for the meeting store",
            "refactor how we record calls",
            "rename the meeting file",
            "call Pablo",
            "arregla la llamada a la API",
        ])
    }

    func testCodeThatCarriesTheWordIsNotACall() {
        assertLeft([
            "what did the compiler say about the meeting store",
            "what does the call to fetchCalls return?",
            "where was the meeting store defined",
            "¿Por qué falla la llamada a la API?",
        ])
    }

    func testEmptyIsNothing() {
        XCTAssertFalse(CallQuestion.isAboutPastCalls(""))
        XCTAssertFalse(CallQuestion.isAboutPastCalls("   "))
        XCTAssertFalse(CallQuestion.isAboutPastCalls("?"))
    }

    // MARK: - Words

    func testTokensFoldAndRememberPossessives() {
        let tokens = CallText.tokens("Tuesday’s REUNIÓN, stand-up y 1:1")
        XCTAssertEqual(tokens.map(\.text), ["tuesday", "reunion", "standup", "y", "oneonone"])
        XCTAssertEqual(tokens.map(\.possessive), [true, false, false, false, false])
    }
}
