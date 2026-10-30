import XCTest
@testable import AirlockCore

final class CallLanguageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC

    // MARK: - Which languages a call is listened for in

    /// Nothing picked for calls is what every call did before there was a
    /// choice: dictation's two languages.
    // MARK: - A recording heard again

    func testSpanishWordsFromAnEnglishHearingAreHeardAgainInSpanish() {
        // What an English recogniser made of a Spanish voice message.
        let words = "E se me a corridor, una nova servicio, que meterlo dentro, ablia que guitar "
            + "la respuesta, venti cuatro horas, se tiene que llamar a servicios especiales"
        let reading = CallLanguage.reading(of: words)
        XCTAssertEqual(CallLanguage.hearAgain(heardIn: "en_US", reading: reading, known: ["en", "es", "pt", "it"]),
                       reading.top?.code)
        XCTAssertNotEqual(reading.top?.code, "en")
    }

    func testWordsInTheLanguageHeardStand() {
        let reading = CallLanguage.Reading(hypotheses: ["es": 0.95], characters: 300)
        XCTAssertNil(CallLanguage.hearAgain(heardIn: "es_ES", reading: reading, known: ["en", "es"]))
    }

    func testAFewWordsOrAWeakLeanStand() {
        XCTAssertNil(CallLanguage.hearAgain(heardIn: "en_US",
                                            reading: .init(hypotheses: ["es": 0.95], characters: 12),
                                            known: ["en", "es"]))
        XCTAssertNil(CallLanguage.hearAgain(heardIn: "en_US",
                                            reading: .init(hypotheses: ["es": 0.4, "pt": 0.3], characters: 300),
                                            known: ["en", "es"]))
    }

    func testALanguageThisMacCannotHearStands() {
        let reading = CallLanguage.Reading(hypotheses: ["eu": 0.9], characters: 300)
        XCTAssertNil(CallLanguage.hearAgain(heardIn: "en_US", reading: reading, known: ["en", "es"]))
    }

    func testNothingPickedForCallsFollowsDictation() {
        let wanted = CallLanguage.wanted(callPrimary: "", callSecondary: "",
                                         dictationPrimary: "es_ES", dictationSecondary: "en_US")
        XCTAssertEqual(wanted, .init(primary: "es_ES", secondary: "en_US", fromDictation: true))
    }

    /// Dictation following the system stays that way on calls too.
    func testDictationFollowingTheSystemStaysEmpty() {
        let wanted = CallLanguage.wanted(callPrimary: "", callSecondary: "",
                                         dictationPrimary: "", dictationSecondary: "")
        XCTAssertEqual(wanted, .init(primary: "", secondary: "", fromDictation: true))
    }

    /// A call language of your own never picks up dictation's second, which
    /// was chosen for a different conversation.
    func testACallLanguageComesWithItsOwnSecondOnly() {
        XCTAssertEqual(CallLanguage.wanted(callPrimary: "en_GB", callSecondary: "",
                                           dictationPrimary: "es_ES", dictationSecondary: "fr_FR"),
                       .init(primary: "en_GB", secondary: "", fromDictation: false))
        XCTAssertEqual(CallLanguage.wanted(callPrimary: "en_GB", callSecondary: "de_DE",
                                           dictationPrimary: "es_ES", dictationSecondary: "fr_FR"),
                       .init(primary: "en_GB", secondary: "de_DE", fromDictation: false))
    }

    /// A second call language left over after going back to "Same as
    /// dictation" is not mixed into dictation's pair.
    func testALeftOverCallSecondIsIgnored() {
        XCTAssertEqual(CallLanguage.wanted(callPrimary: "", callSecondary: "de_DE",
                                           dictationPrimary: "es_ES", dictationSecondary: ""),
                       .init(primary: "es_ES", secondary: "", fromDictation: true))
    }

    // MARK: - Which language the notes are written in

    /// The text is all the model reads: an English call heard by a Spanish
    /// recogniser still comes out in English words.
    func testLongSureTextOutranksTheRecogniser() {
        let decision = CallLanguage.decide(engine: ["es_ES"],
                                           reading: .init(hypotheses: ["en": 0.99, "es": 0.01], characters: 900))
        XCTAssertEqual(decision, .init(code: "en", name: "English", source: .text))
    }

    /// A few words can lean to a neighbouring language.
    func testShortTextDefersToTheRecogniser() {
        let decision = CallLanguage.decide(engine: ["es_ES"],
                                           reading: .init(hypotheses: ["pt": 0.92, "es": 0.08], characters: 40))
        XCTAssertEqual(decision, .init(code: "es", name: "Spanish", source: .engine))
    }

    /// A call that switches between two languages is not sure of either.
    func testUnsureTextDefersToTheRecogniser() {
        let decision = CallLanguage.decide(engine: ["en_US"],
                                           reading: .init(hypotheses: ["es": 0.6, "en": 0.4], characters: 4_000))
        XCTAssertEqual(decision?.code, "en")
        XCTAssertEqual(decision?.source, .engine)
    }

    /// Each side settles on its own language; when they differ, the one the
    /// text leans to.
    func testSidesThatDifferAreSettledByTheText() {
        let decision = CallLanguage.decide(engine: ["en_US", "es_ES"],
                                           reading: .init(hypotheses: ["es": 0.6, "en": 0.4], characters: 4_000))
        XCTAssertEqual(decision, .init(code: "es", name: "Spanish", source: .engine))
    }

    func testSidesThatDifferWithNoTextKeepTheFirst() {
        let decision = CallLanguage.decide(engine: ["en_US", "es_ES"],
                                           reading: .init(hypotheses: [:], characters: 0))
        XCTAssertEqual(decision?.code, "en")
    }

    /// Two regions of one language are one language.
    func testRegionsOfOneLanguageAreOne() {
        let decision = CallLanguage.decide(engine: ["es_ES", "es-MX"],
                                           reading: .init(hypotheses: [:], characters: 0))
        XCTAssertEqual(decision, .init(code: "es", name: "Spanish", source: .engine))
    }

    func testNothingToGoOnNamesNothing() {
        XCTAssertNil(CallLanguage.decide(engine: [], reading: .init(hypotheses: [:], characters: 0)))
        XCTAssertNil(CallLanguage.decide(engine: [], reading: .init(hypotheses: ["es": 0.3], characters: 20)))
    }

    /// Nothing from the recogniser: the text alone, when it leans clearly.
    func testWithNoRecogniserTheTextAloneDecides() {
        let decision = CallLanguage.decide(engine: [],
                                           reading: .init(hypotheses: ["fr": 0.7], characters: 30))
        XCTAssertEqual(decision, .init(code: "fr", name: "French", source: .text))
    }

    // MARK: - The whole check, on real words

    func testASpanishCallIsWrittenInSpanish() {
        let check = CallLanguage.check(record(languages: ["es_ES"], [
            "Vale, entonces el lunes mandamos el presupuesto al cliente y el martes lo revisamos.",
            "Perfecto, y antes del jueves tenemos que cerrar las fechas con el equipo de diseño.",
            "De acuerdo, yo me encargo de llamar a la agencia esta misma tarde para confirmarlo.",
        ]))
        XCTAssertEqual(check.decision, .init(code: "es", name: "Spanish", source: .text))
    }

    func testAnEnglishCallHeardInSpanishIsWrittenInEnglish() {
        let check = CallLanguage.check(record(languages: ["es_ES"], [
            "Okay so we ship on Friday and then review the numbers with the team on Monday morning.",
            "Sounds good. I will send the slides to everyone before the launch meeting on Thursday.",
            "Great, and let's ask the design team to check the pricing page one more time as well.",
        ]))
        XCTAssertEqual(check.decision?.name, "English")
        XCTAssertEqual(check.decision?.source, .text)
    }

    func testAShortCallKeepsTheRecognisersLanguage() {
        let check = CallLanguage.check(record(languages: ["es_ES"], ["Hola. Sí. Vale."]))
        XCTAssertEqual(check.decision, .init(code: "es", name: "Spanish", source: .engine))
    }

    /// meetings.log gets languages and numbers, never a word of the call.
    func testTheLogLineHoldsNoWordsOfTheCall() {
        let check = CallLanguage.check(record(languages: ["es_ES"], [
            "Vale, entonces el lunes mandamos el presupuesto al cliente y el martes lo revisamos.",
            "Perfecto, y antes del jueves tenemos que cerrar las fechas con el equipo de diseño.",
            "De acuerdo, yo me encargo de llamar a la agencia esta misma tarde para confirmarlo.",
        ]))
        let line = check.logLine
        XCTAssertTrue(line.hasPrefix("language check: engine es_ES, text es "), line)
        XCTAssertTrue(line.hasSuffix("→ Spanish, from the text"), line)
        for word in ["presupuesto", "cliente", "agencia", "Vale"] {
            XCTAssertFalse(line.contains(word), line)
        }
    }

    func testTheLogLineSaysWhenNothingIsKnown() {
        let check = CallLanguage.Check(engine: [], reading: .init(hypotheses: [:], characters: 0), decision: nil)
        XCTAssertEqual(check.logLine, "language check: engine none, text none over 0 chars → not named")
    }

    private func record(languages: [String], _ lines: [String]) -> MeetingRecord {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   languages: languages)
        for (index, line) in lines.enumerated() {
            let speaker: MeetingSpeaker = index.isMultiple(of: 2) ? .them : .me
            record.add(MeetingSegment(speaker: speaker, start: Double(index * 10),
                                      end: Double(index * 10 + 6), text: line))
        }
        return record
    }
}
