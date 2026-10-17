import XCTest
@testable import AirlockCore

final class MeetingTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func record(_ segments: [MeetingSegment]) -> MeetingRecord {
        MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start, segments: segments)
    }

    private func said(_ speaker: MeetingSpeaker, _ start: TimeInterval, _ end: TimeInterval,
                      _ text: String = "words") -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: end, text: text)
    }

    // MARK: - The merge

    func testSpeechTypedNotesAndPausesComeInTheOrderTheyHappened() {
        var call = record([said(.them, 5, 9, "Budget?"), said(.me, 13, 15, "Friday."),
                           said(.me, 150, 152, "Back again.")])
        call.jot("Budget by Friday", at: 12)
        call.pause(at: 20)
        call.resume(at: 140)
        call.pause(at: 200)

        XCTAssertEqual(MeetingTimeline.entries(of: call), [
            .speech(said(.them, 5, 9, "Budget?"), marked: false),
            .jot(MeetingJot(at: 12, text: "Budget by Friday")),
            .speech(said(.me, 13, 15, "Friday."), marked: false),
            .pause(MeetingPause(start: 20, end: 140)),
            .speech(said(.me, 150, 152, "Back again."), marked: false),
            .pause(MeetingPause(start: 200)),
        ])
    }

    func testAtTheSameMomentSpeechComesFirstThenTheNoteThenThePause() {
        var call = record([said(.me, 30, 34)])
        call.pause(at: 30)
        call.jot("Typed then", at: 30)
        XCTAssertEqual(MeetingTimeline.entries(of: call).map(\.at), [30, 30, 30])
        XCTAssertEqual(MeetingTimeline.entries(of: call).map(\.isSpeech), [true, false, false])
        guard case .jot = MeetingTimeline.entries(of: call)[1] else { return XCTFail("the note is second") }
    }

    /// Lines by one speaker close together read as one turn, as in the file.
    func testSpeechIsGroupedIntoTurns() {
        let call = record([said(.me, 3, 5, "Hi."), said(.me, 6, 8, "On the train."), said(.them, 9, 11)])
        XCTAssertEqual(MeetingTimeline.entries(of: call), [
            .speech(said(.me, 3, 8, "Hi. On the train."), marked: false),
            .speech(said(.them, 9, 11), marked: false),
        ])
    }

    func testATurnWithinAMarksReachIsMarked() {
        var call = record([said(.them, 10, 20), said(.me, 100, 110), said(.them, 200, 210)])
        call.mark(at: 120)
        XCTAssertEqual(MeetingTimeline.entries(of: call).map { entry -> Bool in
            if case .speech(_, let marked) = entry { return marked }
            return false
        }, [false, true, false])
    }

    /// The window and the file are the same merge, so they cannot disagree.
    func testTheFileFollowsTheSameOrder() {
        var call = record([said(.them, 5, 9, "Budget?"), said(.me, 13, 15, "Friday.")])
        call.jot("Budget by Friday", at: 12)
        let text = MeetingFiles.transcript(of: call, timeZone: TimeZone(identifier: "UTC")!)
        let note = text.range(of: "**Your note** · 0:12")?.lowerBound
        let them = text.range(of: "**Them** · 0:05")?.lowerBound
        let you = text.range(of: "**You** · 0:13")?.lowerBound
        XCTAssertNotNil(note)
        XCTAssertTrue(them! < note! && note! < you!, text)
    }

    func testAnEmptyCallHasNothingInIt() {
        XCTAssertEqual(MeetingTimeline.entries(of: record([])), [])
    }

    // MARK: - Long turns, as the windows draw them

    /// Forty lines of 99 characters by one voice, a second apart: one turn
    /// of almost 4,000 characters in the file.
    private var monologue: MeetingRecord {
        record((0..<40).map { line in
            said(.them, TimeInterval(line * 6), TimeInterval(line * 6 + 5), String(repeating: "word ", count: 20).dropLast() + "\(line % 10)")
        })
    }

    private func turns(_ entries: [MeetingTimeline.Entry]) -> [MeetingSegment] {
        entries.compactMap { entry in
            if case .speech(let turn, _) = entry { return turn }
            return nil
        }
    }

    /// One row taller than about 5,000 points draws black, so the windows
    /// never get one turn that long: it carries on in the rows below,
    /// broken between lines, each with its own real times.
    func testALongTurnIsShownInPiecesBrokenBetweenLines() {
        let whole = turns(MeetingTimeline.entries(of: monologue))
        let shown = turns(MeetingTimeline.shown(of: monologue))
        XCTAssertEqual(whole.count, 1)
        XCTAssertEqual(shown.count, 3)
        XCTAssertTrue(shown.allSatisfy { $0.text.count <= MeetingTimeline.longestShown })
        XCTAssertEqual(shown.map(\.text).joined(separator: " "), whole[0].text)
        // Each piece starts where one of its lines started.
        let starts = Set(monologue.segments.map(\.start))
        XCTAssertTrue(shown.allSatisfy { starts.contains($0.start) })
        XCTAssertEqual(shown.first?.start, whole[0].start)
        XCTAssertEqual(shown.last?.end, whole[0].end)
    }

    /// Only drawn: the file, and what the notes are written from, keep the
    /// turn whole, under one name.
    func testTheFileKeepsTheTurnWhole() {
        let text = MeetingFiles.transcript(of: monologue, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text.components(separatedBy: "**Them** ·").count - 1, 1)
        XCTAssertEqual(NumberedTranscript(monologue).turns.count, 1)
    }

    /// The pieces read as one person talking on: one face and name, then
    /// only the words, and what they say next still carries on the last.
    func testThePiecesGoUnderOneFace() {
        let shown = MeetingTimeline.shown(of: monologue)
        XCTAssertEqual(CallLive.headed(shown, in: monologue).entries, [true, false, false])
        let words = CallLive.Hearing(speaker: .them, text: "and so on", since: start.addingTimeInterval(240))
        XCTAssertTrue(CallLive.continues(words, after: shown, startedAt: start))
    }

    /// A line too long on its own is cut at spaces, timed by its share.
    func testOneVeryLongLineIsCutAtSpaces() {
        let text = String(repeating: "word ", count: 800).dropLast()
        let long = said(.me, 100, 500, String(text))
        let shown = turns(MeetingTimeline.shown(of: record([long])))
        XCTAssertEqual(shown.count, 3)
        XCTAssertTrue(shown.allSatisfy { $0.text.count <= MeetingTimeline.longestShown })
        XCTAssertTrue(shown.allSatisfy { !$0.text.hasPrefix(" ") && !$0.text.hasSuffix(" ") })
        XCTAssertEqual(shown.map(\.text).joined(separator: " "), long.text)
        XCTAssertEqual(shown.first?.start, 100)
        XCTAssertEqual(shown.last?.end, 500)
        XCTAssertEqual(zip(shown, shown.dropFirst()).filter { $0.end > $1.start }.count, 0)
    }

    /// A word longer than a piece is cut where it has to be.
    func testAWordWithNoSpacesIsCutAnyway() {
        let long = said(.them, 0, 10, String(repeating: "x", count: 3_200))
        XCTAssertEqual(turns(MeetingTimeline.shown(of: record([long]))).map(\.text.count), [1_500, 1_500, 200])
    }

    /// A short call is drawn exactly as the file reads it.
    func testShortTurnsAreShownAsTheyAre() {
        var call = record([said(.them, 5, 9, "Budget?"), said(.me, 13, 15, "Friday.")])
        call.jot("Budget by Friday", at: 12)
        XCTAssertEqual(MeetingTimeline.shown(of: call), MeetingTimeline.entries(of: call))
    }

    // MARK: - Where a line of notes points

    private var spaced: [MeetingTimeline.Entry] {
        var call = record([said(.them, 4, 11), said(.me, 23.4, 31), said(.them, 95, 104)])
        call.jot("Mine", at: 50)
        call.pause(at: 60)
        call.resume(at: 80)
        return MeetingTimeline.entries(of: call)
    }

    func testALinePointsToTheTurnSaidAtItsTime() {
        // speech 4, speech 23.4, jot 50, pause 60, speech 95
        XCTAssertEqual(MeetingTimeline.spoken(at: 4, in: spaced), 0)
        XCTAssertEqual(MeetingTimeline.spoken(at: 95, in: spaced), 4)
    }

    /// The page writes 23.4 s as "0:23"; read back, that is 23, and it must
    /// still find the turn it came from rather than the one before.
    func testAWholeSecondFindsATurnThatStartedPartWayThroughIt() {
        XCTAssertEqual(MeetingTimeline.spoken(at: 23, in: spaced), 1)
    }

    func testBetweenTurnsItIsTheNearestOneBefore() {
        XCTAssertEqual(MeetingTimeline.spoken(at: 10, in: spaced), 0)
        // A typed note or a pause in between is never what a line points to.
        XCTAssertEqual(MeetingTimeline.spoken(at: 50, in: spaced), 1)
        XCTAssertEqual(MeetingTimeline.spoken(at: 70, in: spaced), 1)
        XCTAssertEqual(MeetingTimeline.spoken(at: 4_000, in: spaced), 4)
    }

    func testBeforeAnythingWasSaidItIsTheFirstTurnAfter() {
        XCTAssertEqual(MeetingTimeline.spoken(at: 0, in: spaced), 0)
        var call = record([said(.me, 30, 34)])
        call.jot("Early", at: 2)
        let entries = MeetingTimeline.entries(of: call)
        XCTAssertEqual(MeetingTimeline.spoken(at: 2, in: entries), 1)
    }

    func testNothingSaidMeansNowhereToPoint() {
        var call = record([])
        call.jot("Alone", at: 5)
        XCTAssertNil(MeetingTimeline.spoken(at: 5, in: MeetingTimeline.entries(of: call)))
        XCTAssertNil(MeetingTimeline.spoken(at: 5, in: []))
    }

    // MARK: - Pauses, in words

    func testAPauseSaysWhenItRan() {
        XCTAssertEqual(MeetingTimeline.pauseLabel(MeetingPause(start: 723, end: 845)), "Paused 12:03–14:05")
        XCTAssertEqual(MeetingTimeline.pauseLabel(MeetingPause(start: 723)), "Paused from 12:03")
        XCTAssertEqual(MeetingTimeline.pauseLabel(MeetingPause(start: 3_600, end: 3_729)), "Paused 1:00:00–1:02:09")
    }
}
