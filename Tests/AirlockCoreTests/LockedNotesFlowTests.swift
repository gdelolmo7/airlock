import XCTest
@testable import AirlockCore

/// With the server's key in the build, Free's notes don't stop at 30
/// minutes: the rest of the call is locked, still heard, and said so.
final class LockedNotesFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private let boot: TimeInterval = 86_400
    private let half = PlanLimits.freeNotesListen

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private func zoom(at date: Date) -> OngoingCall {
        OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: date)
    }

    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event, _ seconds: TimeInterval,
                      plan: PlanSnapshot = .free, locks: Bool = true) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: true, autoStart: false, running: boot + seconds, plan: plan, locks: locks)
    }

    private func look(_ flow: inout MeetingNotesFlow, _ seconds: TimeInterval, callOnMic: Bool? = nil,
                      plan: PlanSnapshot = .free, locks: Bool = true) -> [MeetingNotesFlow.Effect] {
        send(&flow, .tick(.init(now: at(seconds), callOnMic: callOnMic, lastSpeech: at(seconds))), seconds,
             plan: plan, locks: locks)
    }

    private func notes(plan: PlanSnapshot = .free, locks: Bool = true) -> MeetingNotesFlow {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .callStarted(zoom(at: now), at: now), 0, plan: plan, locks: locks)
        _ = send(&flow, .accept(at: now), 0, plan: plan, locks: locks)
        return flow
    }

    private func isRecording(_ flow: MeetingNotesFlow) -> Bool {
        if case .recording = flow.phase { return true }
        return false
    }

    func testAtTheLimitTheRestIsLockedOnceAndTheNotesGoOn() {
        var flow = notes()
        XCTAssertEqual(look(&flow, half - 1), [])
        XCTAssertFalse(flow.locked)
        XCTAssertEqual(look(&flow, half), [.lockNotes])
        XCTAssertTrue(flow.locked)
        XCTAssertTrue(isRecording(flow), "still listening")
        XCTAssertFalse(flow.stoppedAtLimit)
        XCTAssertEqual(look(&flow, half + 1), [], "locked once")
        XCTAssertEqual(look(&flow, half * 3), [])
        XCTAssertTrue(isRecording(flow))
    }

    func testWithoutTheKeyTheNotesStopAsBefore() {
        var flow = notes(locks: false)
        XCTAssertEqual(look(&flow, half, locks: false), [.finishNotes])
        XCTAssertFalse(flow.locked)
        XCTAssertTrue(flow.stoppedAtLimit)
    }

    func testPlusIsNeverLocked() {
        let plus = PlanSnapshot(plan: .plus, isPaid: true)
        var flow = notes(plan: plus)
        XCTAssertEqual(look(&flow, half * 2, plan: plus), [])
        XCTAssertFalse(flow.locked)
    }

    /// Locked notes end the ways notes end, and stay locked while written
    /// and ready, until they are put away.
    func testLockedNotesEndAsUsualAndStayLockedUntilDismissed() {
        var flow = notes()
        _ = look(&flow, half)
        XCTAssertEqual(send(&flow, .stop, half + 600), [.finishNotes])
        XCTAssertTrue(flow.locked)
        _ = send(&flow, .saved(folder: "f"), half + 605)
        XCTAssertTrue(flow.locked)
        XCTAssertEqual(flow.limitWord(running: boot + half + 605, plan: .free, locks: true), .kept)
        _ = send(&flow, .dismiss, half + 700)
        XCTAssertFalse(flow.locked)
        XCTAssertNil(flow.limitWord(running: boot + half + 700, plan: .free, locks: true))
    }

    func testQuietForFifteenMinutesStillEndsLockedNotes() {
        var flow = notes()
        _ = look(&flow, half)
        let quiet = at(half + MeetingNotesFlow.silenceLimit)
        XCTAssertEqual(send(&flow, .tick(.init(now: quiet, lastSpeech: at(half))), half + MeetingNotesFlow.silenceLimit),
                       [.finishNotes])
        XCTAssertTrue(flow.locked)
    }

    /// The call drops and is back within the window: it carries on, locked,
    /// with no offer, though its notes are used up.
    func testTheSameCallBackSoonCarriesOnLocked() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .callEnded(at: at(half + 600)), half + 600)
        XCTAssertEqual(look(&flow, half + 600 + MeetingNotesFlow.micHold, callOnMic: false), [.finishNotes])
        _ = send(&flow, .saved(folder: "f"), half + 610)
        let back = half + 660
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(back)), at: at(back)), back),
                       [.startNotes(zoom(at: at(back)), continuing: true)])
        XCTAssertTrue(isRecording(flow))
        XCTAssertTrue(flow.locked, "back locked")
        XCTAssertEqual(look(&flow, back + 60), [], "and not locked a second time")
    }

    /// Without the key, the same call back is not offered notes: they are
    /// used up, as before.
    func testWithoutTheKeyTheSameCallBackIsUsedUp() {
        var flow = notes(locks: false)
        _ = look(&flow, half, locks: false)
        _ = send(&flow, .saved(folder: "f"), half + 5, locks: false)
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(half + 60)), at: at(half + 60)), half + 60, locks: false),
                       [])
        XCTAssertFalse(isRecording(flow))
    }

    /// Stopped by hand, locked notes don't come back by themselves.
    func testStoppedByHandTheCallBackIsNotTakenAgain() {
        var flow = notes()
        _ = look(&flow, half)
        _ = send(&flow, .stop, half + 60)
        _ = send(&flow, .saved(folder: "f"), half + 65)
        _ = send(&flow, .callEnded(at: at(half + 70)), half + 70)
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(half + 90)), at: at(half + 90)), half + 90), [])
        XCTAssertFalse(isRecording(flow))
    }

    // MARK: - The words

    func testTheWordsAroundALockedCall() {
        var flow = notes()
        _ = look(&flow, half - 300)
        XCTAssertEqual(flow.limitWord(running: boot + half - 300, plan: .free, locks: true), .locksSoon)
        XCTAssertEqual(flow.limitWord(running: boot + half - 300, plan: .free), .stopsSoon)
        _ = look(&flow, half)
        XCTAssertEqual(flow.limitWord(running: boot + half, plan: .free, locks: true), .stillListening)

        typealias Word = MeetingNotesFlow.LimitWord
        XCTAssertEqual(Word.locksSoon.pillWord, "Notes stop at 30 min")
        XCTAssertEqual(Word.stillListening.pillWord, "Still listening")
        XCTAssertEqual(Word.kept.pillWord, "Notes ready")
        XCTAssertEqual(Word.locksSoon.line,
                       "Free's notes cover the first 30 minutes. After that Airlock goes on listening "
                        + "and holds the rest 7 days, for Plus.")
        XCTAssertEqual(Word.stillListening.line,
                       "Your notes cover the first 30 minutes. The rest is kept 7 days, for Plus.")
        XCTAssertEqual(Word.kept.line, "Notes cover the first 30 minutes. The rest is kept 7 days, for Plus.")
    }

    func testTheLockedCallWords() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let until = Date(timeIntervalSince1970: 1_792_073_400) // Thursday 15 October 2026, 14:10 UTC
        XCTAssertEqual(LockedCallWords.day(until, timeZone: utc), "Thursday 15 October")
        XCTAssertEqual(LockedCallWords.clock(until, timeZone: utc), "14:10")
        XCTAssertEqual(LockedCallWords.ready(minutes: 12, until: until, timeZone: utc),
                       "Notes cover the first 30 minutes. The last 12 are kept until Thursday 15 October, for Plus.")
        XCTAssertEqual(LockedCallWords.ready(minutes: 1, until: until, timeZone: utc),
                       "Notes cover the first 30 minutes. The last minute is kept until Thursday 15 October, for Plus.")
        XCTAssertEqual(LockedCallWords.kept(minutes: 12, until: until, timeZone: utc),
                       "The last 12 minutes are kept on this Mac until Thursday 15 October. "
                        + "Plus opens them and writes notes of the whole call.")
        XCTAssertEqual(LockedCallWords.removed(minutes: 12, on: until, timeZone: utc),
                       "The other 12 minutes were kept for 7 days and removed on Thursday 15 October.")
        XCTAssertEqual(LockedCallWords.removed(minutes: 1, on: until, timeZone: utc),
                       "The other minute was kept for 7 days and removed on Thursday 15 October.")
        XCTAssertEqual(LockedCallWords.waitingTitle(minutes: 12), "12 more minutes are waiting")
        XCTAssertEqual(LockedCallWords.waitingTitle(minutes: 1), "1 more minute is waiting")
        XCTAssertEqual(LockedCallWords.waitingDetail(from: until.addingTimeInterval(-720), to: until,
                                                     until: until, timeZone: utc),
                       "13:58 to 14:10, kept on this Mac until Thursday 15 October. "
                        + "Plus opens them and writes notes of the whole call.")
        XCTAssertEqual(LockedCallWords.redoQuestion(title: "Weekly sync", when: "Today 9:00", minutes: 52),
                       "Write the notes of “Weekly sync” (Today 9:00, 52 min) again, for the whole call?")
        XCTAssertEqual(LockedCallWords.redoReason(opened: 22),
                       "Free's notes covered the first 30 minutes. The other 22 were kept on this Mac, and are open now.")
    }
}
