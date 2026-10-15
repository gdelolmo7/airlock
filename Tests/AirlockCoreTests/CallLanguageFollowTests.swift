import XCTest
@testable import AirlockCore

/// Following a call into another language: when a side starts a second take,
/// in which locale, and when that take is allowed to take over.
final class CallLanguageFollowTests: XCTestCase {
    private typealias Follow = CallLanguageFollow

    /// `count` of `total` lines in Catalan, spread as evenly as they come.
    private func spread(_ count: Int, of total: Int) -> [String] {
        (0..<total).map { index in
            (index + 1) * count / total > index * count / total ? "ca" : "es"
        }
    }

    /// Feeds the lines to a Spanish take's watch; the line at which it first
    /// leans elsewhere, or nil.
    private func firstTrigger(_ lines: [String], into watch: inout Follow.Watch) -> Int? {
        for (index, language) in lines.enumerated() {
            watch.add(language, at: Double(index) * 10)
            if watch.other != nil { return index }
        }
        return nil
    }

    // MARK: - The watch

    /// The real call's Spanish ten minutes: 1 line in 13 and then 0 in 49
    /// read as Catalan. Nothing starts.
    func testTheSpanishStretchOfTheRealCallStartsNothing() {
        var watch = Follow.Watch(own: "es")
        XCTAssertNil(firstTrigger(spread(1, of: 13) + spread(0, of: 49), into: &watch))
    }

    /// Up to about 7% never reaches three in a dozen, however long it runs.
    func testSevenPercentNeverTriggers() {
        var watch = Follow.Watch(own: "es")
        XCTAssertNil(firstTrigger(Array(repeating: spread(1, of: 14), count: 20).flatMap { $0 }, into: &watch))
        var even = Follow.Watch(own: "es")
        XCTAssertNil(firstTrigger(spread(2, of: 28), into: &even))
    }

    /// Every share the real call's Catalan stretch read at, from 27% to
    /// 78%, starts a second take within one window.
    func testEveryCatalanShareOfTheRealCallTriggersWithinAWindow() {
        for (count, total) in [(4, 15), (4, 11), (2, 5), (12, 25), (1, 2), (7, 9)] {
            var watch = Follow.Watch(own: "es")
            let at = firstTrigger(spread(count * 4, of: total * 4), into: &watch)
            XCTAssertNotNil(at, "\(count) in \(total)")
            XCTAssertLessThan(at ?? .max, Follow.Watch.window, "\(count) in \(total)")
            XCTAssertEqual(watch.other, "ca")
        }
    }

    /// The real call as a whole: quiet for ten minutes of Spanish, then
    /// Catalan at its lowest share is caught within a dozen lines.
    func testTheRealCallIsCaughtAfterItsSwitch() {
        var watch = Follow.Watch(own: "es")
        let spanish = spread(1, of: 13) + spread(0, of: 49)
        XCTAssertNil(firstTrigger(spanish, into: &watch))
        let at = firstTrigger(spread(4, of: 15) + spread(4, of: 15), into: &watch)
        XCTAssertNotNil(at)
        XCTAssertLessThan(at ?? .max, 12)
    }

    /// Lines too short to read do not count, and do not push read lines out.
    func testShortLinesDoNotCount() {
        var watch = Follow.Watch(own: "es")
        watch.add("ca", at: 0)
        watch.add("ca", at: 10)
        for second in 0..<30 { watch.add(nil, at: 20 + Double(second)) }
        watch.add("ca", at: 60)
        XCTAssertEqual(watch.lines.count, 3)
        XCTAssertEqual(watch.other, "ca")
    }

    /// Two other languages at once: the one with more lines.
    func testTheStrongerOtherLanguageWins() {
        var watch = Follow.Watch(own: "es")
        for (index, language) in ["it", "ca", "it", "ca", "it", "ca", "ca"].enumerated() {
            watch.add(language, at: Double(index))
        }
        XCTAssertEqual(watch.other, "ca")
    }

    /// The take's own language is never "another".
    func testTheOwnLanguageNeverTriggers() {
        var watch = Follow.Watch(own: "ca")
        for index in 0..<12 { watch.add("ca", at: Double(index)) }
        XCTAssertNil(watch.other)
    }

    // MARK: - Reading a line

    func testALineReadsAsItsLanguage() {
        let codes: Set<String> = ["es", "ca", "en", "pt", "it", "fr", "de"]
        XCTAssertEqual(Follow.language(of: "Mañana revisamos el presupuesto con todo el equipo de ventas.",
                                       among: codes), "es")
        XCTAssertEqual(Follow.language(of: "Demà revisarem el pressupost amb tot l'equip de vendes.",
                                       among: codes), "ca")
        XCTAssertEqual(Follow.language(of: "Domani rivediamo il bilancio con tutta la squadra.",
                                       among: codes), "it")
    }

    /// "Sí, vale, perfecto." reads as anything.
    func testAShortLineIsNotRead() {
        XCTAssertNil(Follow.language(of: "Sí, vale, perfecto.", among: ["es", "ca"]))
    }

    // MARK: - Which take the words on screen follow

    /// Spanish spoken, English tried first: the English take's words for it
    /// (as heard) read as Spanish, so the screen moves to the Spanish take.
    func testTheScreenMovesToTheTakeWhoseWordsReadAsItsOwn() {
        let english = "Holaal com del Valencia de la se quene"
        let spanish = "Hola, qué tal? Oye, quería comentarte lo del viaje a Valencia"
        XCTAssertEqual(Follow.shown([("en_US", "en", english), ("es_ES", "es", spanish)], showing: "en_US"),
                       "es_ES")
        // English spoken, Spanish tried first: Spanish writes it in English.
        let said = "Okay so I was thinking we could go over the plan next week"
        XCTAssertEqual(Follow.shown([("es_ES", "es", said), ("en_US", "en", said)], showing: "es_ES"), "en_US")
    }

    /// The take showing keeps the screen while its words read as its own,
    /// even when another's do too, and while nobody's can be read yet.
    func testTheScreenStaysWhileItsWordsReadAsItsOwnOrNothingCanBeRead() {
        let spanish = "Hola, qué tal? Oye, quería comentarte lo del viaje a Valencia"
        XCTAssertEqual(Follow.shown([("en_US", "en", spanish), ("es_ES", "es", spanish)], showing: "es_ES"),
                       "es_ES")
        XCTAssertEqual(Follow.shown([("en_US", "en", "Hola"), ("es_ES", "es", "Hola")], showing: "en_US"),
                       "en_US")
        XCTAssertEqual(Follow.shown([("en_US", "en", ""), ("es_ES", "es", "")], showing: "en_US"), "en_US")
    }

    // MARK: - Which locale

    private let speech = ["de_AT", "de_CH", "de_DE", "en_AU", "en_CA", "en_GB", "en_IE", "en_IN", "en_US",
                          "es_CL", "es_ES", "es_MX", "es_US", "fr_BE", "fr_CA", "fr_CH", "fr_FR",
                          "it_CH", "it_IT", "pt_BR", "pt_PT"]
    private let dictation = ["ca_ES", "de_DE", "en_GB", "en_US", "es_ES", "it_IT", "nl_NL", "pt_BR", "pt_PT"]

    /// Catalan only dictation knows.
    func testCatalanIsHeardByDictation() {
        XCTAssertEqual(Follow.listener(for: "ca", speech: speech, dictation: dictation, near: ["es_ES"]),
                       .init(identifier: "ca_ES", module: .dictation))
    }

    /// Speech first, whenever it knows the language.
    func testSpeechIsPreferred() {
        XCTAssertEqual(Follow.listener(for: "it", speech: speech, dictation: dictation, near: ["es_ES"]),
                       .init(identifier: "it_IT", module: .speech))
    }

    /// Portuguese on a Spanish call: the neighbour, not the biggest.
    func testPortugueseOnASpanishCallIsPortugal() {
        XCTAssertEqual(Follow.listener(for: "pt", speech: speech, dictation: dictation,
                                       near: ["es_ES", "en_US"])?.identifier, "pt_PT")
        XCTAssertEqual(Follow.listener(for: "pt", speech: speech, dictation: dictation,
                                       near: ["es_MX"])?.identifier, "pt_BR")
    }

    /// The take's country, then the Mac's.
    func testTheMacsCountryCounts() {
        XCTAssertEqual(Follow.listener(for: "en", speech: speech, dictation: dictation,
                                       near: ["es_ES", "en_US"])?.identifier, "en_US")
        XCTAssertEqual(Follow.listener(for: "es", speech: speech, dictation: dictation,
                                       near: ["en_US"])?.identifier, "es_US")
    }

    /// The Mac's own locale with a region keyword (`en_US@rg=eszzzz`: US
    /// English, formatted for Spain) is still English, and still the US for
    /// English; for any other language it says the person is in Spain.
    func testTheMacsRegionKeyword() {
        let mac = "en_US@rg=eszzzz"
        XCTAssertEqual(CallLanguage.code(of: mac), "en")
        XCTAssertEqual(Follow.listener(for: "en", speech: speech, dictation: dictation,
                                       near: ["es_ES", mac])?.identifier, "en_US")
        XCTAssertEqual(Follow.listener(for: "es", speech: speech, dictation: dictation,
                                       near: [mac])?.identifier, "es_ES")
        XCTAssertEqual(Follow.listener(for: "pt", speech: speech, dictation: dictation,
                                       near: [mac])?.identifier, "pt_PT")
    }

    /// Several in the same continent: the language's own country.
    func testWithinAContinentTheLanguagesOwnCountry() {
        XCTAssertEqual(Follow.listener(for: "de", speech: speech, dictation: dictation,
                                       near: ["es_ES"])?.identifier, "de_DE")
        XCTAssertEqual(Follow.listener(for: "fr", speech: speech, dictation: dictation,
                                       near: ["es_ES"])?.identifier, "fr_FR")
    }

    func testALanguageNobodyHearsHasNoListener() {
        XCTAssertNil(Follow.listener(for: "eu", speech: speech, dictation: dictation, near: ["es_ES"]))
        XCTAssertEqual(Follow.listener(for: "nl", speech: speech, dictation: dictation, near: [])?.identifier,
                       "nl_NL")
    }

    // MARK: - Confirming, with the measured numbers

    private func speech(_ confidence: Double, _ words: Int) -> Follow.Hearing {
        .init(module: .speech, words: words, confidence: confidence)
    }

    private func dictation(_ confidence: Double?, _ words: Int) -> Follow.Hearing {
        .init(module: .dictation, words: words, confidence: confidence)
    }

    /// Italian heard by es_ES speech: it_IT takes over, either recogniser.
    func testItalianAudioSwitches() {
        let heardInSpanish = speech(0.801, 256)
        XCTAssertTrue(Follow.confirms(challenger: speech(0.960, 267), incumbent: heardInSpanish))
        XCTAssertTrue(Follow.confirms(challenger: dictation(0.901, 269), incumbent: heardInSpanish))
    }

    /// Spanish heard by es_ES speech, three voices: nothing else takes over.
    func testSpanishAudioStays() {
        let voices: [(spanish: Follow.Hearing, italian: Follow.Hearing, italianDictation: Follow.Hearing,
                      catalan: Follow.Hearing)] = [
            (speech(0.983, 402), speech(0.861, 394), dictation(0.413, 272), dictation(nil, 346)),
            (speech(0.940, 403), speech(0.752, 390), dictation(0.318, 190), dictation(nil, 100)),
            (speech(0.945, 404), speech(0.744, 389), dictation(0.298, 186), dictation(nil, 96)),
        ]
        for voice in voices {
            XCTAssertFalse(Follow.confirms(challenger: voice.italian, incumbent: voice.spanish))
            XCTAssertFalse(Follow.confirms(challenger: voice.italianDictation, incumbent: voice.spanish))
            XCTAssertFalse(Follow.confirms(challenger: voice.catalan, incumbent: voice.spanish))
        }
    }

    /// Catalan heard by es_ES speech: ca_ES dictation has no confidence, and
    /// takes over by hearing as many words.
    func testCatalanAudioSwitchesByWords() {
        XCTAssertTrue(Follow.confirms(challenger: dictation(nil, 304), incumbent: speech(0.817, 310)))
    }

    /// Back to Spanish: es_ES speech takes over from whichever took the call.
    func testSpanishAudioSwitchesBack() {
        let backs: [(winner: Follow.Hearing, spanish: Follow.Hearing)] = [
            (speech(0.861, 394), speech(0.983, 402)),
            (speech(0.752, 390), speech(0.940, 403)),
            (speech(0.744, 389), speech(0.945, 404)),
            (dictation(0.413, 272), speech(0.983, 402)),
            (dictation(nil, 346), speech(0.983, 402)),
            (dictation(nil, 100), speech(0.940, 403)),
            (dictation(nil, 96), speech(0.945, 404)),
        ]
        for back in backs {
            XCTAssertTrue(Follow.confirms(challenger: back.spanish, incumbent: back.winner), "\(back.winner)")
        }
    }

    /// And a shadow that only looks back does not take over a call that is
    /// still in the other language.
    func testAShadowDoesNotTakeBackACallStillInTheOtherLanguage() {
        XCTAssertFalse(Follow.confirms(challenger: speech(0.817, 310), incumbent: dictation(nil, 304)))
        XCTAssertFalse(Follow.confirms(challenger: speech(0.801, 256), incumbent: speech(0.960, 267)))
        XCTAssertFalse(Follow.confirms(challenger: speech(0.801, 256), incumbent: dictation(0.901, 269)))
    }

    /// ca_ES dictation keeps 86% of one Spanish voice's words, and over a
    /// stretch that came to 0.90 either way: words alone handed Spanish
    /// audio to Catalan and back. Spanish speech sure of itself settles it.
    func testASureTakeIsNotOutnumbered() {
        let spanish = speech(0.98, 231)
        let catalanOnSpanish = dictation(nil, 210)
        XCTAssertFalse(Follow.confirms(challenger: catalanOnSpanish, incumbent: spanish))
        XCTAssertTrue(Follow.confirms(challenger: speech(0.99, 96), incumbent: dictation(nil, 96)))
        // Not sure (Spanish speech on Catalan, 0.817): words still decide.
        XCTAssertTrue(Follow.confirms(challenger: dictation(nil, 304), incumbent: speech(0.817, 310)))
        XCTAssertFalse(Follow.confirms(challenger: speech(0.817, 310), incumbent: dictation(nil, 304)))
        // Dictation is sure only lifted: es_ES dictation on Spanish, 0.880.
        XCTAssertTrue(Follow.confirms(challenger: dictation(0.880, 404), incumbent: dictation(nil, 400)))
    }

    func testWithNoConfidenceAnywhereWordsDecide() {
        XCTAssertTrue(Follow.confirms(challenger: dictation(nil, 110), incumbent: dictation(nil, 100)))
        XCTAssertFalse(Follow.confirms(challenger: dictation(nil, 105), incumbent: dictation(nil, 100)))
    }

    func testNothingHeardNeverTakesOver() {
        XCTAssertFalse(Follow.confirms(challenger: speech(0.99, 0), incumbent: speech(0.5, 100)))
        XCTAssertTrue(Follow.confirms(challenger: speech(0.9, 40), incumbent: dictation(nil, 0)))
    }

    // MARK: - Refusals, seam, shadow, pieces

    func testARefusedLanguageWaitsFiveMinutes() {
        var refusals = Follow.Refusals()
        XCTAssertTrue(refusals.allows("ca", at: 100))
        refusals.refuse("ca", at: 100)
        XCTAssertFalse(refusals.allows("ca", at: 399))
        XCTAssertTrue(refusals.allows("ca", at: 400))
        XCTAssertTrue(refusals.allows("it", at: 101))
    }

    /// From the first line that read as the other language, while the audio
    /// is still kept; else from the first line still kept.
    func testTheSeamIsALineStart() {
        var watch = Follow.Watch(own: "es")
        for (start, language) in [(500.0, "es"), (520, "ca"), (540, "es"), (560, "ca"), (580, "ca")] {
            watch.add(language, at: start)
        }
        let starts: [TimeInterval] = [500, 510, 520, 540, 560, 580]
        XCTAssertEqual(Follow.seam(watch: watch, language: "ca", lineStarts: starts, replayFrom: 495), 520)
        XCTAssertEqual(Follow.seam(watch: watch, language: "ca", lineStarts: starts, replayFrom: 530), 560)
        XCTAssertEqual(Follow.seam(watch: watch, language: "it", lineStarts: starts, replayFrom: 505), 510)
        XCTAssertNil(Follow.seam(watch: watch, language: "ca", lineStarts: starts, replayFrom: 600))
    }

    /// Back to the shadow's language: from its last run of lines that did
    /// not read as the winner's, short ones neither starting nor ending it,
    /// never before the winner took over.
    func testTheWayBackStartsWhereTheShadowStoppedReadingTheWinner() {
        let lines: [(start: TimeInterval, language: String?)] = [
            (100, "es"), (110, "ca"), (120, "es"), (130, "ca"), (140, nil), (150, "es"), (160, nil), (170, "es"),
        ]
        XCTAssertEqual(Follow.seamFromOwnLines(lines, winner: "ca", after: 90), 150)
        XCTAssertEqual(Follow.seamFromOwnLines(lines, winner: "ca", after: 155), 170)
        XCTAssertNil(Follow.seamFromOwnLines(lines + [(180, "ca")], winner: "ca", after: 90))
        XCTAssertNil(Follow.seamFromOwnLines([(100, nil)], winner: "ca", after: 0))
    }

    /// Speech names what it heard; dictation writes everything in its own
    /// language, so only speech's reading can place a seam over it.
    func testOnlySpeechOverDictationPlacesItsOwnSeam() {
        XCTAssertTrue(Follow.challengerPlacesTheSeam(challenger: .speech, winner: .dictation))
        XCTAssertFalse(Follow.challengerPlacesTheSeam(challenger: .dictation, winner: .speech))
        XCTAssertFalse(Follow.challengerPlacesTheSeam(challenger: .speech, winner: .speech))
        XCTAssertFalse(Follow.challengerPlacesTheSeam(challenger: .dictation, winner: .dictation))
    }

    /// The winner's own line, a moment earlier, goes with the seam.
    func testASeamFromAnotherTakeSnapsToTheWinnersLine() {
        let lines: [(start: TimeInterval, end: TimeInterval)] = [(126.2, 129.8), (130.8, 134.4), (135.7, 139.7)]
        XCTAssertEqual(Follow.snap(130.9, to: lines), 130.8)
        XCTAssertEqual(Follow.snap(133.5, to: lines), 133.5, "late in the line: kept")
        XCTAssertEqual(Follow.snap(130.2, to: lines), 130.2, "between lines: kept")
    }

    /// A switch clears what each take read before it.
    func testAWatchForgetsWhatCameBeforeASwitch() {
        var watch = Follow.Watch(own: "es")
        for (start, language) in [(10.0, "ca"), (20, "ca"), (30, "ca"), (40, "es")] { watch.add(language, at: start) }
        XCTAssertEqual(watch.other, "ca")
        watch.forget(before: 35)
        XCTAssertEqual(watch.lines.map(\.start), [40])
        XCTAssertNil(watch.other)
    }

    func testAShadowSaysBackOnlyOnEnoughLines() {
        var shadow = Follow.Watch(own: "es")
        for index in 0..<7 { shadow.add("es", at: Double(index)) }
        XCTAssertFalse(Follow.shadowSaysBack(shadow, winner: "ca"), "seven lines are too few")
        shadow.add("ca", at: 7)
        XCTAssertTrue(Follow.shadowSaysBack(shadow, winner: "ca"), "one in eight is noise")
        shadow.add("ca", at: 8)
        XCTAssertFalse(Follow.shadowSaysBack(shadow, winner: "ca"))
    }

    /// A long dictation result is cut where the speaker paused.
    func testADictationResultIsCutAtItsPauses() {
        let runs: [Follow.Timed] = [
            .init(text: "bon dia", start: 0.0, end: 0.6),
            .init(text: " ", start: nil, end: nil),
            .init(text: "a tothom", start: 0.7, end: 1.2),
            .init(text: " avui", start: 2.1, end: 2.4),
            .init(text: " parlem", start: 2.5, end: 2.9),
            .init(text: " del pressupost", start: 3.5, end: 4.2),
        ]
        XCTAssertEqual(Follow.pieces(of: runs), [
            .init(text: "bon dia a tothom", start: 0.0, end: 1.2),
            .init(text: "avui parlem", start: 2.1, end: 2.9),
            .init(text: "del pressupost", start: 3.5, end: 4.2),
        ])
    }

    /// A one-word piece is a pause to think, not a line: it joins the
    /// neighbour it is nearer in time.
    func testAOneWordPieceJoinsItsNearerNeighbour() {
        let runs: [Follow.Timed] = [
            .init(text: "la setmana passada", start: 0.0, end: 1.5),
            .init(text: " vam", start: 2.1, end: 2.3),
            .init(text: " tancar el pressupost", start: 3.5, end: 5.0),
            .init(text: " Setmana", start: 6.0, end: 6.4),
            .init(text: " que ve parlem", start: 7.0, end: 8.0),
        ]
        XCTAssertEqual(Follow.pieces(of: runs), [
            .init(text: "la setmana passada vam", start: 0.0, end: 2.3),
            .init(text: "tancar el pressupost", start: 3.5, end: 5.0),
            .init(text: "Setmana que ve parlem", start: 6.0, end: 8.0),
        ])
        XCTAssertEqual(Follow.pieces(of: [.init(text: "Jo", start: 0, end: 0.3)]),
                       [.init(text: "Jo", start: 0, end: 0.3)], "alone, it stays")
    }

    // MARK: - Over the same stretch

    /// Lines across the ends count for their share of the time inside: a
    /// dictation piece that starts a moment before the stretch ends is
    /// mostly outside it.
    func testATakeIsHeardOverTheStretchByTime() {
        let lines: [Follow.Said] = [
            .init(start: 8, end: 12, words: 8, weighted: 0.5 * 40, scored: 40),
            .init(start: 12, end: 20, words: 20, weighted: 0.9 * 100, scored: 100),
            .init(start: 29, end: 33, words: 12, weighted: 0.9 * 60, scored: 60),
        ]
        let hearing = Follow.hearing(lines, module: .speech, from: 10, until: 30)
        // Half of the first, all of the second, a quarter of the third.
        XCTAssertEqual(hearing.words, 4 + 20 + 3)
        let confidence = (0.5 * 20 + 0.9 * 100 + 0.9 * 15) / (20 + 100 + 15)
        XCTAssertEqual(hearing.confidence ?? 0, confidence, accuracy: 1e-9)
        XCTAssertEqual(Follow.hearing(lines, module: .dictation, from: 40, until: 50).words, 0)
        XCTAssertNil(Follow.hearing([.init(start: 10, end: 14, words: 9)], module: .dictation,
                                    from: 0, until: 20).confidence, "no confidence given, none made up")
    }

    func testAnUntimedResultStaysWhole() {
        XCTAssertEqual(Follow.pieces(of: [.init(text: " hola ", start: nil, end: nil)]),
                       [.init(text: "hola", start: nil, end: nil)])
        XCTAssertEqual(Follow.pieces(of: []), [])
    }

    func testLanguageNames() {
        XCTAssertEqual(Follow.name(of: "ca_ES"), "Catalan")
        XCTAssertEqual(Follow.name(of: "es"), "Spanish")
        XCTAssertNil(Follow.name(of: ""))
    }
}
