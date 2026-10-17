import XCTest
@testable import AirlockCore

/// Call notes on Free stop listening at 30 minutes, counted in the Mac's
/// running time from the call's first notes, and nothing gets around it:
/// not the clock, not a stop and a start, not a quit, not notes in the room.
final class FreeNotesListenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    /// The Mac's running time at `now`.
    private let boot: TimeInterval = 86_400
    private let plus = PlanSnapshot(plan: .plus, isPaid: true)
    private let half = PlanLimits.freeNotesListen

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private func zoom(at date: Date) -> OngoingCall {
        OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: date)
    }
    private func teams(at date: Date) -> OngoingCall {
        OngoingCall(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams", startedAt: date)
    }

    /// An event `seconds` after `now`, by the clock and by running time
    /// alike unless `running` says the clock moved on its own.
    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event, _ seconds: TimeInterval,
                      running: TimeInterval? = nil, plan: PlanSnapshot = .free) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: true, autoStart: false, running: boot + (running ?? seconds), plan: plan)
    }

    /// A look with somebody talking, so only the cap can end the notes.
    private func look(_ flow: inout MeetingNotesFlow, _ seconds: TimeInterval, clock: TimeInterval? = nil,
                      plan: PlanSnapshot = .free) -> [MeetingNotesFlow.Effect] {
        let shown = at(clock ?? seconds)
        return send(&flow, .tick(.init(now: shown, lastSpeech: shown)), clock ?? seconds,
                    running: seconds, plan: plan)
    }

    /// Notes of a Zoom call, taken from `seconds`.
    private func notes(from seconds: TimeInterval = 0, plan: PlanSnapshot = .free) -> MeetingNotesFlow {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .callStarted(zoom(at: at(seconds)), at: at(seconds)), seconds, plan: plan)
        _ = send(&flow, .accept(at: at(seconds)), seconds, plan: plan)
        return flow
    }

    private func isRecording(_ flow: MeetingNotesFlow) -> Bool {
        if case .recording = flow.phase { return true }
        return false
    }

    // MARK: - The cap

    func testFreeNotesStopListeningAtThirtyMinutesAndKeepWhatWasHeard() {
        var flow = notes()
        XCTAssertEqual(look(&flow, half - 1), [])
        XCTAssertTrue(isRecording(flow))
        XCTAssertEqual(look(&flow, half), [.finishNotes], "written, not dropped")
        XCTAssertEqual(flow.phase, .writing(zoom(at: now)))
        XCTAssertTrue(flow.stoppedAtLimit)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        XCTAssertTrue(flow.stoppedAtLimit, "still said once the notes are ready")
        _ = send(&flow, .dismiss, half + 60)
        XCTAssertFalse(flow.stoppedAtLimit)
    }

    /// The pill and the card say it five minutes before, then that the notes
    /// stopped, and never on a plan without the limit.
    func testTheWordsBeforeAndAfterTheLimit() {
        var flow = notes()
        _ = look(&flow, half - 301)
        XCTAssertNil(flow.limitWord(running: boot + half - 301, plan: .free))
        _ = look(&flow, half - 300)
        XCTAssertEqual(flow.limitWord(running: boot + half - 300, plan: .free), .stopsSoon)
        _ = look(&flow, half)
        XCTAssertEqual(flow.limitWord(running: boot + half, plan: .free), .stopped)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        XCTAssertEqual(flow.limitWord(running: boot + half + 5, plan: .free), .stopped)
        _ = send(&flow, .dismiss, half + 60)
        XCTAssertNil(flow.limitWord(running: boot + half + 60, plan: .free))

        var plusNotes = notes(plan: plus)
        _ = look(&plusNotes, half - 60, plan: plus)
        XCTAssertNil(plusNotes.limitWord(running: boot + half - 60, plan: plus))

        XCTAssertEqual(MeetingNotesFlow.LimitWord.stopsSoon.pillWord, "Notes stop at 30 min")
        XCTAssertEqual(MeetingNotesFlow.LimitWord.stopsSoon.line,
                       "Notes stop at 30 minutes on Free. The call itself goes on.")
        XCTAssertEqual(MeetingNotesFlow.LimitWord.stopped.line,
                       "The first 30 minutes are saved. Plus takes notes of the whole call.")
    }

    func testWithoutARunningTimeNothingIsCounted() {
        var flow = MeetingNotesFlow()
        _ = flow.apply(.callStarted(zoom(at: now), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        let late = at(half * 3)
        XCTAssertEqual(flow.apply(.tick(.init(now: late, lastSpeech: late)), enabled: true, autoStart: false), [])
        XCTAssertNil(flow.listening)
    }

    func testPlusAndProListenForTheWholeCall() {
        for plan in [plus, PlanSnapshot(plan: .pro, isPaid: true)] {
            var flow = notes(plan: plan)
            XCTAssertEqual(look(&flow, half * 4, plan: plan), [])
            XCTAssertTrue(isRecording(flow))
        }
    }

    // MARK: - Ways around it

    /// The clock set forward or back during a call: the count goes by the
    /// Mac's running time, which never moves for a clock change.
    func testChangingTheClockDuringTheCallChangesNothing() {
        var forward = notes()
        XCTAssertEqual(look(&forward, 600, clock: 600 + 3 * 3600), [], "two hours ahead on the clock, 10 minutes in")
        XCTAssertTrue(isRecording(forward))

        var back = notes()
        XCTAssertEqual(look(&back, 600, clock: 600 - 3600), [])
        XCTAssertEqual(look(&back, half, clock: half - 3600), [.finishNotes],
                       "an hour back on the clock does not buy an hour")
    }

    func testAPauseDoesNotCount() {
        var flow = notes()
        _ = send(&flow, .pause(at: at(600)), 600)
        _ = send(&flow, .resume(at: at(1800)), 1800)
        XCTAssertEqual(look(&flow, half + 1199), [], "20 minutes paused, 29:59 listened")
        XCTAssertTrue(isRecording(flow))
        XCTAssertEqual(look(&flow, half + 1200), [.finishNotes])
    }

    /// Stopped by hand, then the call drops and comes back: offered again,
    /// and the new notes carry on the same count.
    func testStoppingAndStartingAgainCarriesOnTheCount() {
        var flow = notes()
        _ = send(&flow, .stop, 1200)
        _ = send(&flow, .saved(folder: "f"), 1205)
        _ = send(&flow, .callEnded(at: at(1500)), 1500)
        _ = send(&flow, .callStarted(zoom(at: at(1560)), at: at(1560)), 1560)
        _ = send(&flow, .accept(at: at(1560)), 1560)
        XCTAssertTrue(isRecording(flow))
        XCTAssertEqual(look(&flow, 1560 + 599), [], "20 + 9:59 minutes")
        XCTAssertEqual(look(&flow, 1560 + 600), [.finishNotes], "20 + 10 minutes")
    }

    /// Used up, the same call is not offered notes again however long it
    /// lasts, and "Take notes" in the room does not start them either.
    func testUsedUpTheCallIsNotOfferedAgain() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: at(3 * 3600)), 3 * 3600), [])
        XCTAssertFalse(isRecording(flow))
        // The detector finds the call again (after a wake, say), hours on.
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: now), at: at(4 * 3600)), 4 * 3600), [])
        XCTAssertNotEqual(flow.phase, .offering(zoom(at: now)))
        // It drops and is back a minute later.
        _ = send(&flow, .callEnded(at: at(5 * 3600)), 5 * 3600)
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(5 * 3600 + 60)), at: at(5 * 3600 + 60)), 5 * 3600 + 60), [])
        XCTAssertNotEqual(flow.phase, .offering(zoom(at: at(5 * 3600 + 60))))
    }

    /// Stopped by hand while the call goes on: notes started again hours
    /// later in the same call, even in the room, carry on its count.
    func testStartingAgainDuringTheSameCallCarriesOnHoweverLate() {
        var flow = notes()
        _ = send(&flow, .stop, 1200)
        _ = send(&flow, .saved(folder: "f"), 1205)
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: at(4 * 3600)), 4 * 3600),
                       [.startNotes(.inPerson(at: at(4 * 3600)), continuing: false)])
        XCTAssertEqual(look(&flow, 4 * 3600 + 599), [])
        XCTAssertEqual(look(&flow, 4 * 3600 + 600), [.finishNotes], "the room notes carry on the call's count")
    }

    func testWithinTenMinutesOfTheEndItCarriesOnAndAfterItIsANewMeeting() {
        func used() -> MeetingNotesFlow {
            var flow = notes()
            _ = look(&flow, half)
            _ = send(&flow, .saved(folder: "f"), half + 5)
            _ = send(&flow, .callEnded(at: at(2400)), 2400)
            _ = send(&flow, .dismiss, 2410)
            return flow
        }
        var soon = used()
        XCTAssertEqual(send(&soon, .callStarted(zoom(at: at(2400 + 599)), at: at(2400 + 599)), 2400 + 599), [])
        XCTAssertEqual(soon.phase, .idle, "9:59 after the end: the same meeting, used up")

        var later = used()
        _ = send(&later, .callStarted(zoom(at: at(2400 + 601)), at: at(2400 + 601)), 2400 + 601)
        XCTAssertEqual(later.phase, .offering(zoom(at: at(2400 + 601))), "10:01 after: a new meeting")
        _ = send(&later, .accept(at: at(2400 + 601)), 2400 + 601)
        XCTAssertEqual(look(&later, 2400 + 601 + half - 1), [])
        XCTAssertTrue(isRecording(later), "with its own 30 minutes")
    }

    /// The ten minutes go by running time too: a clock set forward does not
    /// pass them at once.
    func testTheTenMinutesCannotBeSkippedWithTheClock() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        _ = send(&flow, .callEnded(at: at(2400)), 2400)
        _ = send(&flow, .dismiss, 2410)
        let jumped = at(2400 + 86_400)
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: jumped), at: jumped), 2400 + 86_400, running: 2460), [])
        XCTAssertEqual(flow.phase, .idle)
    }

    func testACallInAnotherAppIsAnotherMeeting() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        _ = send(&flow, .callStarted(teams(at: at(half + 60)), at: at(half + 60)), half + 60)
        XCTAssertEqual(flow.phase, .offering(teams(at: at(half + 60))))
    }

    /// The count is kept across a quit; the call it was of is taken as over
    /// when it was kept, so only the ten minutes after carry it on.
    func testAQuitAndRelaunchCarriesOnTheCountForTenMinutes() throws {
        var before = notes()
        _ = look(&before, 1500)
        let kept = try XCTUnwrap(before.listening?.kept(at: boot + 1500))
        let data = try JSONEncoder().encode(kept)
        let back = try JSONDecoder().decode(NotesListening.self, from: data)

        var soon = MeetingNotesFlow()
        soon.restore(back)
        _ = send(&soon, .callStarted(zoom(at: at(1800)), at: at(1800)), 1800)
        _ = send(&soon, .accept(at: at(1800)), 1800)
        XCTAssertEqual(look(&soon, 1800 + 299), [])
        XCTAssertEqual(look(&soon, 1800 + 300), [.finishNotes], "25 minutes before the quit, 5 after")

        var nextDay = MeetingNotesFlow()
        nextDay.restore(back)
        _ = send(&nextDay, .callStarted(zoom(at: at(86_400)), at: at(86_400)), 86_400)
        _ = send(&nextDay, .accept(at: at(86_400)), 86_400)
        XCTAssertEqual(look(&nextDay, 86_400 + half - 1), [])
        XCTAssertTrue(isRecording(nextDay), "the next day's call has its own 30 minutes")
    }

    /// A restart of the Mac starts its running time again: a count from
    /// before it is over.
    func testARestartOfTheMacEndsTheCount() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .saved(folder: "f"), half + 5)
        _ = send(&flow, .callStarted(zoom(at: at(half + 120)), at: at(half + 120)), half + 120, running: -boot + 60)
        XCTAssertEqual(flow.phase, .offering(zoom(at: at(half + 120))))
    }

    // MARK: - The plan is the call's

    func testACallStartedOnPlusKeepsFullNotesWhenThePlanEnds() {
        var flow = notes(plan: plus)
        XCTAssertEqual(look(&flow, half * 2, plan: .free), [])
        XCTAssertTrue(isRecording(flow), "Plus when the call started: no cap halfway through")
    }

    func testBuyingPlusMidCallLiftsTheCap() {
        var flow = notes()
        XCTAssertEqual(look(&flow, half - 60), [])
        XCTAssertEqual(look(&flow, half * 2, plan: plus), [])
        XCTAssertTrue(isRecording(flow))
    }

    func testRoomNotesAreCappedToo() {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .takeNotesInPerson(at: now), 0)
        XCTAssertEqual(look(&flow, half - 1), [])
        XCTAssertEqual(look(&flow, half), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(.inPerson(at: now)))
    }

    // MARK: - The count itself

    func testTheCountAddsOnlyListeningStretches() {
        var count = NotesListening(startedOn: .free, call: zoom(at: now), at: 100)
        XCTAssertEqual(count.listened(at: 160), 60)
        count.close(at: 160)
        XCTAssertEqual(count.listened(at: 900), 60, "nothing while closed")
        count.open(at: 900)
        count.open(at: 950)
        XCTAssertEqual(count.listened(at: 1000), 160, "opening twice opens once")
        XCTAssertEqual(count.left(at: 1000, plan: .free), half - 160)
        XCTAssertNil(count.left(at: 1000, plan: plus))
    }
}
