import XCTest
@testable import AirlockCore

final class CallVoicesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func record(_ segments: [MeetingSegment], attendees: [String] = []) -> MeetingRecord {
        MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start, segments: segments,
                      event: attendees.isEmpty ? nil : MeetingEvent(title: "Sync", start: start, attendees: attendees))
    }

    private func said(_ speaker: MeetingSpeaker, _ start: TimeInterval, _ end: TimeInterval,
                      _ text: String, person: Int? = nil) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: end, text: text, person: person)
    }

    /// `text` as the recogniser times it: one run per word, evenly spread.
    private func timed(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> [CallLanguageFollow.Timed] {
        let words = text.split(separator: " ")
        let step = (end - start) / Double(words.count)
        return words.enumerated().map { i, word in
            CallLanguageFollow.Timed(text: (i == 0 ? "" : " ") + word,
                                     start: start + Double(i) * step, end: start + Double(i + 1) * step)
        }
    }

    private func span(_ voice: Int, _ start: TimeInterval, _ end: TimeInterval) -> CallVoices.Span {
        CallVoices.Span(voice: voice, start: start, end: end)
    }

    private let first = "We should ship the new build this week"
    private let second = "I can take the release notes then"
    private let third = "Great so that is settled for Friday"

    // MARK: - Numbering

    func testTwoVoicesAreNumberedInTheOrderTheyFirstSpoke() {
        var call = record([said(.them, 1, 19, first), said(.me, 19, 20, "Okay."),
                           said(.them, 21, 44, second), said(.them, 46, 59, third)])
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59)
        // The model's own numbers say nothing about order: 3 spoke first.
        let outcome = CallVoices.number(&call, spans: [span(3, 0, 20), span(0, 20, 45), span(3, 45, 60)],
                                        words: words)

        XCTAssertEqual(outcome.heard, 2)
        XCTAssertEqual(outcome.people, 2)
        XCTAssertEqual(outcome.folded, 0)
        XCTAssertEqual(call.segments.map(\.person), [1, nil, 2, 1])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Person 1", "You", "Person 2", "Person 1"])
    }

    func testAOneToOneCallIsNeverSplitAndKeepsTheName() {
        var call = record([said(.them, 1, 19, first), said(.them, 21, 44, second)], attendees: ["Ana García"])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 20), span(1, 20, 45)],
                                        words: timed(first, 1, 19) + timed(second, 21, 44))

        XCTAssertEqual(outcome.reason, "one-to-one call")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Ana García", "Ana García"])
    }

    func testOneVoiceHeardStaysThem() {
        var call = record([said(.them, 1, 19, first), said(.them, 21, 44, second)])
        let outcome = CallVoices.number(&call, spans: [span(4, 0, 45)], words: timed(first, 1, 19))
        XCTAssertEqual(outcome.reason, "one voice heard")
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Them", "Them"])
    }

    func testAVoiceHeardTooLittleIsFoldedIntoItsNeighbour() {
        // Two seconds of a second "voice" in a minute: a moment of
        // crosstalk, the same person turning away from the mic. Not believed.
        var call = record([said(.them, 1, 30, first), said(.them, 31, 33, "Sorry go on"),
                           said(.them, 37, 60, second)])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 30.5), span(1, 30.5, 33.5), span(0, 36.5, 61)],
                                        words: timed(first, 1, 30) + timed("Sorry go on", 31, 33)
                                            + timed(second, 37, 60))
        XCTAssertEqual(outcome.folded, 1)
        XCTAssertEqual(outcome.reason, "one voice after folding")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil])
    }

    func testInAShortChatTheSecondPersonIsKept() {
        // Twenty seconds in person, the second person speaking for four:
        // under the fifteen-second floor, which folded every second person
        // in a chat this short into the first.
        let mine = "Y mira por ejemplo yo me pongo a hablar contigo"
        let yours = "Pero sí está chulo"
        var call = record([said(.them, 0, 14, mine), said(.them, 14.5, 18.5, yours)])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 14.2), span(1, 14.2, 19)],
                                        words: timed(mine, 0, 14) + timed(yours, 14.5, 18.5))
        XCTAssertEqual(outcome.people, 2)
        XCTAssertEqual(call.segments.map(\.person), [1, 2])
    }

    func testInAShortChatAGreetingIsAPerson() {
        // Half a minute in person, the second person saying only a two-second
        // greeting in the middle of a line: three seconds was the floor, and
        // folded them into the first.
        let mine = "Vale en teoría esto debería estar poniendo todo en tiempo real a ver habla tú"
        let yours = "Hola qué tal cómo andas"
        let after = "No aparentemente no lo diferencia"
        let text = mine + " " + yours
        var call = record([said(.them, 1, 16, text), said(.them, 17, 23.5, after)])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 14), span(1, 14, 16.2), span(0, 16.8, 24)],
                                        words: timed(mine, 1, 14) + timed(yours, 14.1, 16) + timed(after, 17, 23.5))
        XCTAssertEqual(outcome.people, 2)
        XCTAssertEqual(outcome.split, 1)
        XCTAssertEqual(call.segments.map(\.text), [mine, yours, after])
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 1])
    }

    func testInAShortChatALaughIsStillNotAPerson() {
        var call = record([said(.them, 0, 17, first), said(.them, 17.2, 18.7, "Ha ha ha")])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 17.1), span(1, 17.1, 19)],
                                        words: timed(first, 0, 17) + timed("Ha ha ha", 17.2, 18.7))
        XCTAssertEqual(outcome.folded, 1)
        XCTAssertEqual(outcome.reason, "one voice after folding")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil])
    }

    func testALongLaughOrAYesYesIsNotTalk() {
        // Three seconds is over the floor; a laugh is still not someone
        // joining in.
        var call = record([said(.them, 0, 17, first), said(.them, 17.2, 20.2, "Ja, ja, ja, ja.")])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 17.1), span(1, 17.1, 21)],
                                        words: timed(first, 0, 17) + timed("Ja, ja, ja, ja.", 17.2, 20.2))
        XCTAssertEqual(outcome.folded, 1)
        XCTAssertEqual(call.segments.map(\.person), [nil, nil])
        XCTAssertFalse(CallVoices.isTalk("Sí, sí."))
        XCTAssertFalse(CallVoices.isTalk("Mm"))
        XCTAssertTrue(CallVoices.isTalk("Sí, claro"))
    }

    func testTheTalkNeededToBeBelievedGrowsWithTheMeeting() {
        XCTAssertEqual(CallVoices.fewestSeconds(outOf: 18), 1.5, accuracy: 0.001)
        XCTAssertEqual(CallVoices.fewestSeconds(outOf: 60), 3, accuracy: 0.001)
        XCTAssertEqual(CallVoices.fewestSeconds(outOf: 200), 10, accuracy: 0.001)
        XCTAssertEqual(CallVoices.fewestSeconds(outOf: 600), 30, accuracy: 0.001)
    }

    func testThreeVoicesKeepTheirOwnNumbers() {
        var call = record([said(.them, 0, 20, first), said(.them, 20, 40, second), said(.them, 40, 60, third),
                           said(.them, 60, 80, second)])
        let outcome = CallVoices.number(&call, spans: [span(2, 0, 20), span(5, 20, 40), span(0, 40, 60),
                                                       span(5, 60, 80)],
                                        words: timed(first, 0, 20) + timed(second, 20, 40) + timed(third, 40, 60)
                                            + timed(second, 60, 80))
        XCTAssertEqual(outcome.people, 3)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 3, 2])
    }

    // MARK: - Lines across a change of voice

    func testALineIsCutWhereTheVoiceChanges() {
        // The recogniser ran two people's sentences into one line.
        let text = "Can you send it today Yes I will send it tonight"
        var call = record([said(.them, 0, 40, text), said(.them, 41, 60, third)])
        // Eleven words over 40 s: the sixth, "Yes", starts at 200/11 s.
        let change = 200.0 / 11
        let outcome = CallVoices.number(&call, spans: [span(0, 0, change), span(1, change, 40), span(0, 40, 61)],
                                        words: timed(text, 0, 40) + timed(third, 41, 60))

        XCTAssertEqual(outcome.split, 1)
        XCTAssertEqual(call.segments.map(\.text), ["Can you send it today", "Yes I will send it tonight", third])
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 1])
        XCTAssertEqual(call.segments[1].start, change, accuracy: 0.01)
    }

    func testALineWhoseWordsNoLongerMatchItsTextIsNotCut() {
        // Tidying dropped a word, so the words cannot be laid over the text:
        // the line goes whole to whoever said most of it.
        let heard = "Can you send it today uh Yes I will send it tonight please"
        let text = "Can you send it today Yes I will send it tonight please"
        var call = record([said(.them, 0, 40, text), said(.them, 41, 70, third)])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 15), span(1, 15, 40), span(0, 40, 71)],
                                        words: timed(heard, 0, 40) + timed(third, 41, 70))

        XCTAssertEqual(outcome.split, 0)
        XCTAssertEqual(call.segments.map(\.text), [text, third])
        XCTAssertEqual(call.segments.map(\.person), [1, 2])
    }

    func testAOneWordFlickerBetweenTheSameVoiceIsSmoothedAway() {
        let text = "So the plan is to ship on Friday and then rest"
        var call = record([said(.them, 0, 22, text), said(.them, 30, 60, second)])
        // Voice 1 flickers under one word in the middle of voice 0's line.
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 9.5), span(1, 9.5, 11), span(0, 11, 25),
                                                       span(1, 29, 61)],
                                        words: timed(text, 0, 22) + timed(second, 30, 60))
        XCTAssertEqual(outcome.split, 0)
        XCTAssertEqual(call.segments.map(\.person), [1, 2])
    }

    func testPunctuationOnItsOwnDoesNotCountAsAWord() {
        XCTAssertEqual(CallVoices.spoken("Yes , fine .").map(String.init), ["Yes ,", "fine ."])
        XCTAssertEqual(CallVoices.spoken("Yes, fine.").count, 2)
    }

    // MARK: - A call that dropped and carried on

    func testACallThatCarriedOnNumbersItsNewVoicesAfterTheOldOnes() {
        var call = record([said(.them, 0, 20, first, person: 1), said(.them, 20, 40, second, person: 2),
                           said(.them, 100, 120, third), said(.them, 120, 140, first)])
        let outcome = CallVoices.number(&call, from: 90, spans: [span(0, 95, 120), span(1, 120, 141)],
                                        words: timed(third, 100, 120) + timed(first, 120, 140))
        XCTAssertEqual(outcome.people, 2)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 3, 4])
    }

    // MARK: - While the call goes on

    func testDuringTheCallOnlyTheLinesTheModelHasHeardAreNumbered() {
        var call = record([said(.them, 1, 19, first), said(.them, 21, 44, second), said(.them, 46, 59, third)])
        var numbering = CallVoices.Numbering()
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59)
        let outcome = CallVoices.number(&call, through: 45, spans: [span(3, 0, 20), span(0, 20, 45)],
                                        words: words, numbering: &numbering)

        XCTAssertEqual(outcome.people, 2)
        // The last line is past what the model has heard: it waits.
        XCTAssertEqual(call.segments.map(\.person), [1, 2, nil])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Person 1", "Person 2", "Them"])
    }

    func testPassAfterPassEachVoiceKeepsItsNumber() {
        // B says two seconds early on, too little to be believed, and only
        // later says enough: C, believed first, stays Person 2.
        var call = record([said(.them, 0, 30, first), said(.them, 30, 32, "Sorry go on"),
                           said(.them, 32, 50, second), said(.them, 50, 70, third)])
        let spans = [span(0, 0, 30), span(1, 30, 32), span(2, 32, 50), span(1, 50, 70)]
        let words = timed(first, 0, 30) + timed("Sorry go on", 30, 32) + timed(second, 32, 50) + timed(third, 50, 70)
        var numbering = CallVoices.Numbering()

        _ = CallVoices.number(&call, through: 50, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.segments.map(\.person), [1, 1, 2, nil])

        let outcome = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(outcome.people, 3)
        XCTAssertEqual(call.segments.map(\.person), [1, 3, 2, 3])
        // Run again with nothing new, nothing moves.
        let again = call
        _ = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call, again)
    }

    func testANameGivenDuringTheCallFollowsItsVoiceWhenTheNumbersMove() {
        // Three voices at first; then B turns out to be too little of the
        // call and is folded away, so C moves up from Person 3 to Person 2.
        var call = record([said(.them, 0, 10, first), said(.them, 10, 14, "Sorry go on"),
                           said(.them, 14, 30, second), said(.them, 30, 60, third), said(.them, 60, 90, first)])
        let spans = [span(0, 0, 10), span(1, 10, 14), span(2, 14, 30), span(0, 30, 60), span(2, 60, 90)]
        let words = timed(first, 0, 10) + timed("Sorry go on", 10, 14) + timed(second, 14, 30)
            + timed(third, 30, 60) + timed(first, 60, 90)
        var numbering = CallVoices.Numbering()

        _ = CallVoices.number(&call, through: 30, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 3, nil, nil])
        call.name(2, as: "Ana")
        call.name(3, as: "Marc")

        _ = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.segments.map(\.person), [1, 1, 2, 1, 2])
        XCTAssertEqual(call.names, [MeetingVoiceName(voice: 2, name: "Marc")])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Person 1", "Person 1", "Marc", "Person 1", "Marc"])
    }

    func testWhenTheVoicesTurnOutToBeOneTheLinesAreTheOtherSidesAgain() {
        // Two voices at first; then one of them says so much that the
        // other's five seconds are not believed.
        var call = record([said(.them, 0, 14, first), said(.them, 14, 19, "Sorry go on"),
                           said(.them, 20, 200, second)])
        let spans = [span(0, 0, 14), span(1, 14, 19), span(0, 19, 200)]
        let words = timed(first, 0, 14) + timed("Sorry go on", 14, 19) + timed(second, 20, 200)
        var numbering = CallVoices.Numbering()

        _ = CallVoices.number(&call, through: 19.5, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, nil])
        call.name(1, as: "Marc")
        call.name(2, as: "Ana")

        let outcome = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(outcome.reason, "one voice after folding")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil])
        // The voice left is the whole other side now, and keeps its name.
        XCTAssertEqual(call.names, [MeetingVoiceName(voice: MeetingRecord.otherSide, name: "Marc")])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Marc", "Marc", "Marc"])
    }

    func testACallThatCarriedOnKeepsItsNumbersFromPassToPass() {
        var call = record([said(.them, 0, 20, first, person: 1), said(.them, 20, 40, second, person: 2),
                           said(.them, 100, 120, third), said(.them, 120, 140, first)])
        let spans = [span(0, 95, 120), span(1, 120, 141)]
        let words = timed(third, 100, 120) + timed(first, 120, 140)
        var numbering = CallVoices.Numbering()
        _ = CallVoices.number(&call, from: 90, through: 141, spans: spans, words: words, numbering: &numbering)
        _ = CallVoices.number(&call, from: 90, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 3, 4])
    }

    // MARK: - Naming the other side while the call goes on

    func testTheOtherSideCanBeNamedUntilAnyOfItsLinesHasANumber() {
        let heardAsOne = record([said(.them, 1, 19, first), said(.them, 21, 44, second)])
        XCTAssertTrue(CallVoices.canName(MeetingRecord.otherSide, of: heardAsOne))
        XCTAssertTrue(CallVoices.canName(2, of: heardAsOne))

        let toldApart = record([said(.them, 1, 19, first, person: 1), said(.them, 21, 44, second, person: 2)])
        XCTAssertFalse(CallVoices.canName(MeetingRecord.otherSide, of: toldApart))
        XCTAssertTrue(CallVoices.canName(1, of: toldApart))
        XCTAssertTrue(CallVoices.canName(2, of: toldApart))
    }

    func testInTheRoomTheOtherSideWaitsForTheEndToBeNamed() {
        let room = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: start,
                                 segments: [said(.them, 1, 19, first), said(.them, 21, 44, second)])
        XCTAssertFalse(CallVoices.canName(MeetingRecord.otherSide, of: room))
        XCTAssertTrue(CallVoices.canName(2, of: room))
    }

    func testOnlyTheOtherSideNamedBeforeAnyNumberIsOnePerson() {
        var call = record([said(.them, 1, 19, first), said(.them, 21, 44, second)])
        XCTAssertFalse(CallVoices.isNamedAsOne(call))
        call.name(MeetingRecord.otherSide, as: "Ana")
        XCTAssertTrue(CallVoices.isNamedAsOne(call))

        var toldApart = record([said(.them, 1, 19, first, person: 1), said(.them, 21, 44, second, person: 2)])
        toldApart.name(MeetingRecord.otherSide, as: "Ana")
        toldApart.name(2, as: "Marc")
        XCTAssertFalse(CallVoices.isNamedAsOne(toldApart))

        var room = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: start,
                                 segments: [said(.them, 1, 19, first)])
        room.name(MeetingRecord.otherSide, as: "Ana")
        XCTAssertFalse(CallVoices.isNamedAsOne(room))
    }

    func testTheOtherSideNamedBeforeAnyNumberIsNeverSplit() {
        var call = record([said(.them, 1, 19, first), said(.me, 19, 20, "Okay."), said(.them, 21, 44, second)])
        let spans = [span(3, 0, 20), span(0, 20, 45), span(3, 45, 60)]
        var words = timed(first, 1, 19) + timed(second, 21, 44)
        var numbering = CallVoices.Numbering()
        call.name(MeetingRecord.otherSide, as: "Ana")

        // Two voices heard so far, but the person said who the other side is.
        let soFar = CallVoices.number(&call, through: 45, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(soFar.reason, "the other side was named")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Ana", "You", "Ana"])

        // A line said after the name has it too, and the last pass keeps it.
        call.add(said(.them, 46, 59, third))
        words += timed(third, 46, 59)
        let last = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(last.reason, "the other side was named")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil, nil])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Ana", "You", "Ana", "Ana"])
        XCTAssertEqual(call.names, [MeetingVoiceName(voice: MeetingRecord.otherSide, name: "Ana")])
    }

    func testTheOtherSideNamedWhenOneVoiceWasHeardStaysOnePerson() {
        var call = record([said(.them, 1, 19, first), said(.them, 21, 44, second), said(.them, 46, 59, third)])
        let spans = [span(3, 0, 20), span(0, 20, 45), span(3, 45, 60)]
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59)
        var numbering = CallVoices.Numbering()

        let soFar = CallVoices.number(&call, through: 20, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(soFar.reason, "one voice heard")
        XCTAssertTrue(CallVoices.canName(MeetingRecord.otherSide, of: call))
        call.name(MeetingRecord.otherSide, as: "Ana")

        // The second voice is heard only after the name was given.
        let last = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(last.reason, "the other side was named")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil])
        XCTAssertEqual(call.segments.map { call.label(for: $0) }, ["Ana", "Ana", "Ana"])
    }

    func testANameTheOtherSideTookOverAtAFoldStillLetsTheVoicesBeToldApartAgain() {
        // Two voices; then one says so much that the other's five seconds
        // are folded away and its name goes to the other side; then the
        // other says enough to be believed again.
        var call = record([said(.them, 0, 14, first), said(.them, 14, 19, "Sorry go on"),
                           said(.them, 20, 200, second)])
        var spans = [span(0, 0, 14), span(1, 14, 19), span(0, 19, 200)]
        var words = timed(first, 0, 14) + timed("Sorry go on", 14, 19) + timed(second, 20, 200)
        var numbering = CallVoices.Numbering()
        _ = CallVoices.number(&call, through: 19.5, spans: spans, words: words, numbering: &numbering)
        call.name(1, as: "Marc")
        _ = CallVoices.number(&call, through: 200, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(call.names, [MeetingVoiceName(voice: MeetingRecord.otherSide, name: "Marc")])
        XCTAssertTrue(CallVoices.isNamedAsOne(call))

        call.add(said(.them, 200, 320, third))
        spans.append(span(1, 200, 320))
        words += timed(third, 200, 320)
        let outcome = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertEqual(outcome.people, 2)
        XCTAssertEqual(call.segments.map(\.person), [1, 2, 1, 2])
    }

    func testTheModelsStretchesSoFarCloseTheOpenOnesAtTheLastFrame() {
        var tracker = CallVoices.Tracker(origin: 10)
        tracker.add(Array(repeating: [0.9, 0], count: 50).flatMap { $0 }, frames: 50, voices: 2)
        let heard = tracker.soFar
        XCTAssertEqual(heard.spans, [span(0, 10, 10.5)])
        XCTAssertEqual(heard.through, 10.5, accuracy: 0.001)
        // Still open in the tracker itself: the next frames carry it on.
        tracker.add(Array(repeating: [0.9, 0], count: 50).flatMap { $0 }, frames: 50, voices: 2)
        tracker.finish()
        XCTAssertEqual(tracker.spans.count, 1)
        XCTAssertEqual(tracker.spans[0].end, 11, accuracy: 0.001)
    }

    func testAnHourOfLinesIsNumberedQuickly() {
        // A pass runs on the main actor every ten seconds of a call.
        var segments: [MeetingSegment] = []
        var words: [CallLanguageFollow.Timed] = []
        var spans: [CallVoices.Span] = []
        for i in 0..<900 {
            let start = Double(i) * 4
            segments.append(said(.them, start, start + 3.5, first))
            words += timed(first, start, start + 3.5)
            spans.append(span(i % 3, start, start + 3.6))
        }
        var call = record(segments)
        var numbering = CallVoices.Numbering()
        let started = Date()
        _ = CallVoices.number(&call, spans: spans, words: words, numbering: &numbering)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(Set(call.segments.compactMap(\.person)), [1, 2, 3])
    }

    // MARK: - The shadow

    func testShadowLinesGetTheVoiceSpeakingThrough(){
        var call = record([said(.them, 0, 20, first), said(.them, 20, 40, second)])
        call.addShadow(MeetingShadowLine(segment: said(.them, 21, 39, "Puedo hacer las notas"), language: "es_ES"))
        _ = CallVoices.number(&call, spans: [span(0, 0, 20), span(1, 20, 40)],
                              words: timed(first, 0, 20) + timed(second, 20, 40))
        XCTAssertEqual(call.shadow.map(\.segment.person), [2])
    }

    // MARK: - From the model's frames

    func testFramesBecomeSpansOnTheMeetingsClock() {
        var tracker = CallVoices.Tracker(origin: 100)
        // Voice 0 for 50 frames, then voice 1 for 30 across two deliveries,
        // with a 10-frame blip of voice 2 too short to keep.
        var first: [Float] = []
        for frame in 0..<60 {
            first += [frame < 50 ? 0.9 : 0.1, frame >= 50 ? 0.8 : 0.0, frame < 10 ? 0.7 : 0.0]
        }
        tracker.add(first, frames: 60, voices: 3)
        tracker.add(Array(repeating: [0, 0.9, 0], count: 20).flatMap { $0 }, frames: 20, voices: 3)
        tracker.finish()

        XCTAssertEqual(tracker.frames, 80)
        XCTAssertEqual(tracker.spans.count, 2)
        XCTAssertEqual(tracker.spans[0].voice, 0)
        XCTAssertEqual(tracker.spans[0].start, 100, accuracy: 0.001)
        XCTAssertEqual(tracker.spans[0].end, 100.5, accuracy: 0.001)
        XCTAssertEqual(tracker.spans[1].voice, 1)
        XCTAssertEqual(tracker.spans[1].start, 100.5, accuracy: 0.001)
        XCTAssertEqual(tracker.spans[1].end, 100.8, accuracy: 0.001)
    }

    // MARK: - Labels, turns and files

    func testTurnsNeverJoinTwoPeople() {
        let turns = MeetingFiles.turns([said(.them, 0, 2, "One.", person: 1), said(.them, 2, 4, "Two.", person: 2),
                                        said(.them, 4, 6, "Three.", person: 2)])
        XCTAssertEqual(turns.map(\.text), ["One.", "Two. Three."])
        XCTAssertEqual(turns.map(\.person), [1, 2])
    }

    func testTheTranscriptAndTheNumberedTranscriptNameEachPerson() {
        let call = record([said(.them, 0, 2, "Hello.", person: 1), said(.me, 2, 4, "Hi."),
                           said(.them, 4, 6, "Morning.", person: 2)])
        XCTAssertTrue(MeetingFiles.transcript(of: call).contains("**Person 2** · 0:04"))
        XCTAssertEqual(NumberedTranscript(call).turns.map(\.label), ["Person 1", "You", "Person 2"])
    }

    func testAMeetingFileFromBeforeVoicesOpensWithNobodyNumbered() throws {
        let json = #"{"speaker":"them","start":1,"end":2,"text":"Hi"}"#
        let segment = try JSONDecoder().decode(MeetingSegment.self, from: Data(json.utf8))
        XCTAssertNil(segment.person)
        // And nobody numbered writes no key, so the file reads as before.
        let written = String(decoding: try JSONEncoder().encode(segment), as: UTF8.self)
        XCTAssertFalse(written.contains("person"))
    }

    // MARK: - Who the notes may name

    func testNumberedVoicesCanOwnAToDoWhenTheyWereToldApart() {
        let call = record([said(.them, 0, 2, "Hello.", person: 1), said(.them, 4, 6, "Morning.", person: 2),
                           said(.them, 6, 8, "Hey.", person: 3)])
        let people = MeetingPeople(record: call)
        XCTAssertEqual(people.voices, 3)
        XCTAssertEqual(people.owner("Person 2"), "Person 2")
        XCTAssertEqual(people.owner("person 3."), "Person 3")
        XCTAssertNil(people.owner("Person 7"))
        XCTAssertTrue(people.promptLine.hasPrefix("People on the call: You, and Person 1 to Person 3"))
        XCTAssertEqual(people.voiceLabels, ["Person 1", "Person 2", "Person 3"])
    }

    func testWithoutVoicesNobodyIsAPerson() {
        let people = MeetingPeople(record: record([said(.them, 0, 2, "Hello.")]))
        XCTAssertEqual(people.voices, 0)
        XCTAssertNil(people.owner("Person 1"))
        XCTAssertEqual(people.promptLine, "People on the call: You, and Them (everyone else on the call).")
    }
}
