import XCTest
@testable import AirlockCore

/// In the room, how loud each voice was on the Mac's microphone: the
/// loudest is guessed to be you, and lines said just before a new voice was
/// first heard go to it when they sound like it.
final class CallVoicesRoomTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func room(_ segments: [MeetingSegment]) -> MeetingRecord {
        MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: start,
                      segments: segments)
    }

    private func said(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: .them, start: start, end: end, text: text)
    }

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

    /// The microphone at `amplitude` over each stretch, from the start of
    /// the meeting: ten samples a step, so a test stays small.
    private func loudness(_ parts: [(until: TimeInterval, amplitude: Float)]) -> CallVoices.Loudness {
        var loudness = CallVoices.Loudness(origin: 0, step: 0.1, sampleRate: 100)
        var at: TimeInterval = 0
        for part in parts {
            let count = Int(((part.until - at) * 100).rounded())
            loudness.add(Array(repeating: part.amplitude, count: count))
            at = part.until
        }
        return loudness
    }

    private let first = "We should ship the new build this week"
    private let second = "I can take the release notes then"
    private let third = "Great so that is settled for Friday"
    private let fourth = "And I will tell the shop about the price"

    private let near: Float = 0.3
    private let far: Float = 0.05

    /// Voice 3 near the Mac (Person 1), voice 0 across the table (Person 2).
    private func meeting() -> (record: MeetingRecord, spans: [CallVoices.Span], words: [CallLanguageFollow.Timed],
                               loudness: CallVoices.Loudness) {
        let record = room([said(1, 19, first), said(21, 44, second), said(46, 59, third)])
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59)
        return (record, [span(3, 0, 20), span(0, 20, 45), span(3, 45, 60)], words,
                loudness([(20, near), (45, far), (60, near)]))
    }

    // MARK: - Loudness

    func testLoudnessIsTakenFromTheLouderHalfOfALine() throws {
        let heard = loudness([(1, 0.3), (2, 0)])
        // Half speech, half silence: as loud as the speech.
        let level = try XCTUnwrap(heard.level(from: 0, to: 2))
        XCTAssertEqual(level, 10 * log10(0.09), accuracy: 0.1)
        XCTAssertNil(heard.level(from: 5, to: 6))
    }

    // MARK: - Guessing you

    func testTheLoudestVoiceInTheRoomIsGuessedToBeYou() {
        var (record, spans, words, loudness) = meeting()
        let outcome = CallVoices.number(&record, spans: spans, words: words, loudness: loudness)

        XCTAssertEqual(outcome.guessedYou, 1)
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 1, name: "", isYou: true, guessed: true)])
        XCTAssertEqual(record.segments.map { record.label(for: $0) }, ["You", "Person 2", "You"])
    }

    func testVoicesAboutAsLoudAreNotGuessed() {
        var (record, spans, words, _) = meeting()
        let outcome = CallVoices.number(&record, spans: spans, words: words,
                                        loudness: loudness([(20, near), (45, near * 0.8), (60, near)]))
        XCTAssertNil(outcome.guessedYou)
        XCTAssertTrue(record.names.isEmpty)
    }

    func testNoGuessOnACall() {
        var (record, spans, words, loudness) = meeting()
        record.bundleID = "us.zoom.xos"
        let outcome = CallVoices.number(&record, spans: spans, words: words, loudness: loudness)
        XCTAssertNil(outcome.guessedYou)
        XCTAssertTrue(record.names.isEmpty)
    }

    func testANameGivenToTheGuessedVoiceTakesTheGuessAwayForGood() {
        var (record, spans, words, loudness) = meeting()
        var numbering = CallVoices.Numbering()
        _ = CallVoices.number(&record, spans: spans, words: words, loudness: loudness, numbering: &numbering)
        record.name(1, as: "Ana")
        let outcome = CallVoices.number(&record, spans: spans, words: words, loudness: loudness,
                                        numbering: &numbering)

        XCTAssertEqual(outcome.guessedYou, 1)
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 1, name: "Ana")])
    }

    func testYouSaidByHandIsNeverGuessedOver() {
        var (record, spans, words, loudness) = meeting()
        var numbering = CallVoices.Numbering()
        _ = CallVoices.number(&record, spans: spans, words: words, loudness: loudness, numbering: &numbering)
        // "That's me" on Person 2: the guess on Person 1 goes at once.
        record.name(2, as: nil, isYou: true)
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 2, name: "", isYou: true)])
        _ = CallVoices.number(&record, spans: spans, words: words, loudness: loudness, numbering: &numbering)
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 2, name: "", isYou: true)])
    }

    func testNoGuessOnceThePersonSaidItWasWrong() {
        var (record, spans, words, loudness) = meeting()
        let outcome = CallVoices.number(&record, spans: spans, words: words, loudness: loudness, guessesYou: false)
        XCTAssertNil(outcome.guessedYou)
        XCTAssertTrue(record.names.isEmpty)
    }

    func testTheGuessFollowsItsVoiceWhenItIsNoLongerTheLoudest() {
        var (record, spans, words, loudness) = meeting()
        var numbering = CallVoices.Numbering()
        _ = CallVoices.number(&record, spans: spans, words: words, loudness: loudness, numbering: &numbering)
        _ = CallVoices.number(&record, spans: spans, words: words,
                              loudness: self.loudness([(20, far), (45, near), (60, far)]), numbering: &numbering)
        XCTAssertEqual(record.names, [MeetingVoiceName(voice: 2, name: "", isYou: true, guessed: true)])
    }

    // MARK: - Moving lines back

    func testLinesBeforeANewVoiceWasHeardGoToItWhenTheySoundLikeIt() {
        // The model heard the quiet voice only from 45 s on, and put what it
        // said before under the loud one.
        var record = room([said(1, 19, first), said(21, 44, second), said(46, 59, third), said(61, 80, fourth)])
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59) + timed(fourth, 61, 80)
        let outcome = CallVoices.number(&record, spans: [span(3, 0, 45), span(0, 45, 81)], words: words,
                                        loudness: loudness([(20, near), (81, far)]))

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertEqual(record.segments.map(\.person), [1, 2, 2, 2])
    }

    func testLinesLongBeforeANewVoiceStayWhereTheyAre() {
        var record = room([said(1, 19, first), said(21, 44, second), said(200, 213, third), said(215, 234, fourth)])
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 200, 213) + timed(fourth, 215, 234)
        let outcome = CallVoices.number(&record, spans: [span(3, 0, 199), span(0, 199, 235)], words: words,
                                        loudness: loudness([(20, near), (235, far)]))

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(record.segments.map(\.person), [1, 1, 2, 2])
    }

    func testNothingMovesWithoutLoudness() {
        var record = room([said(1, 19, first), said(21, 44, second), said(46, 59, third), said(61, 80, fourth)])
        let words = timed(first, 1, 19) + timed(second, 21, 44) + timed(third, 46, 59) + timed(fourth, 61, 80)
        let outcome = CallVoices.number(&record, spans: [span(3, 0, 45), span(0, 45, 81)], words: words)

        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(record.segments.map(\.person), [1, 1, 2, 2])
        XCTAssertTrue(record.names.isEmpty)
    }

    // MARK: - Saved names

    func testNamesSavedBeforeGuessesWereAllGivenByHand() throws {
        let old = Data(#"{"voice":2,"name":"","isYou":true}"#.utf8)
        let name = try JSONDecoder().decode(MeetingVoiceName.self, from: old)
        XCTAssertEqual(name, MeetingVoiceName(voice: 2, name: "", isYou: true))
        XCTAssertFalse(name.guessed)

        let guessed = MeetingVoiceName(voice: 1, name: "", isYou: true, guessed: true)
        let back = try JSONDecoder().decode(MeetingVoiceName.self, from: JSONEncoder().encode(guessed))
        XCTAssertEqual(back, guessed)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(name), as: UTF8.self).contains("guessed"))
    }
}
