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
