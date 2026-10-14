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

        XCTAssertEqual(outcome, CallVoices.Outcome(heard: 2, people: 2))
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
        // Five seconds of a second "voice" in a minute: a cough, a laugh, the
        // same person turning away from the mic. Not believed.
        var call = record([said(.them, 1, 30, first), said(.them, 31, 36, "Sorry go on"),
                           said(.them, 37, 60, second)])
        let outcome = CallVoices.number(&call, spans: [span(0, 0, 30.5), span(1, 30.5, 36.5), span(0, 36.5, 61)],
                                        words: timed(first, 1, 30) + timed("Sorry go on", 31, 36)
                                            + timed(second, 37, 60))
        XCTAssertEqual(outcome.folded, 1)
        XCTAssertEqual(outcome.reason, "one voice after folding")
        XCTAssertEqual(call.segments.map(\.person), [nil, nil, nil])
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
