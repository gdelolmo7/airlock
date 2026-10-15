import XCTest
@testable import AirlockCore

final class CallNotesPanelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC

    private func record(_ segments: [MeetingSegment], with: [String] = []) -> MeetingRecord {
        MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, segments: segments,
                      event: with.isEmpty ? nil : MeetingEvent(title: "Stand-up", start: start, attendees: with))
    }

    // MARK: - While notes are taken

    func testTheHeadsUpIsTheExactLineToPaste() {
        XCTAssertEqual(CallNotesPanel.headsUp,
                       "Heads up: I'm taking notes of this call on my Mac. No recording is kept.")
    }

    func testTheHeadsUpIsOfferedForTheFirstMinuteOnly() {
        XCTAssertTrue(CallNotesPanel.showsHeadsUp(notesSince: start, now: start))
        XCTAssertTrue(CallNotesPanel.showsHeadsUp(notesSince: start, now: start.addingTimeInterval(59.9)))
        XCTAssertFalse(CallNotesPanel.showsHeadsUp(notesSince: start, now: start.addingTimeInterval(60)))
        XCTAssertFalse(CallNotesPanel.showsHeadsUp(notesSince: start, now: start.addingTimeInterval(3600)))
    }

    /// Paused, the last half-minute was never written down: nothing to mark.
    func testMarkIsOfferedOnlyWhileNotesAreWrittenDown() {
        let call = OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start)
        let at = { (seconds: TimeInterval) in self.start.addingTimeInterval(seconds) }
        var flow = MeetingNotesFlow()
        XCTAssertFalse(CallNotesPanel.offersMark(flow))
        _ = flow.apply(.callStarted(call, at: start), enabled: true, autoStart: false)
        XCTAssertFalse(CallNotesPanel.offersMark(flow))
        _ = flow.apply(.accept(at: start), enabled: true, autoStart: false)
        XCTAssertTrue(CallNotesPanel.offersMark(flow))

        _ = flow.apply(.pause(at: at(40)), enabled: true, autoStart: false)
        XCTAssertFalse(CallNotesPanel.offersMark(flow))
        _ = flow.apply(.resume(at: at(70)), enabled: true, autoStart: false)
        XCTAssertTrue(CallNotesPanel.offersMark(flow))

        _ = flow.apply(.stop, enabled: true, autoStart: false)
        XCTAssertFalse(CallNotesPanel.offersMark(flow))
    }

    func testAMarkSaysHowFarBackItReaches() {
        XCTAssertEqual(CallNotesPanel.marked, "Marked the last 30 seconds")
    }

    func testTheJotCountShowsOnlyOnceSomethingIsJotted() {
        XCTAssertNil(CallNotesPanel.jotted(0))
        XCTAssertEqual(CallNotesPanel.jotted(1), "1 jotted")
        XCTAssertEqual(CallNotesPanel.jotted(2), "2 jotted")
    }

    func testTheClockReadsMinutesThenHours() {
        XCTAssertEqual(CallNotesPanel.clock(0), "0:00")
        XCTAssertEqual(CallNotesPanel.clock(-5), "0:00")
        XCTAssertEqual(CallNotesPanel.clock(754.9), "12:34")
        XCTAssertEqual(CallNotesPanel.clock(3725), "1:02:05")
    }

    // MARK: - The transcript, live

    func testTheLastFourLinesAreShownOldestFirstWithTheirSpeaker() {
        let lines = (0..<7).map { index in
            MeetingSegment(speaker: index.isMultiple(of: 2) ? .me : .them,
                           start: TimeInterval(index * 10), end: TimeInterval(index * 10 + 4),
                           text: "Line \(index)")
        }
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines)), [
            .init(speaker: "Them", text: "Line 3"),
            .init(speaker: "You", text: "Line 4"),
            .init(speaker: "Them", text: "Line 5"),
            .init(speaker: "You", text: "Line 6"),
        ])
    }

    func testAOneToOneCallNamesTheOtherPerson() {
        let lines = [MeetingSegment(speaker: .them, start: 0, end: 2, text: "Hi there"),
                     MeetingSegment(speaker: .me, start: 3, end: 4, text: "Hello")]
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines, with: ["Ana"])).map(\.speaker),
                       ["Ana", "You"])
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines, with: ["Ana", "Bo"])).map(\.speaker),
                       ["Them", "You"])
    }

    func testTheSpeakersEchoIsLeftOutAsInTheNotes() {
        let lines = [
            MeetingSegment(speaker: .them, start: 10, end: 14, text: "We ship the budget on Friday"),
            MeetingSegment(speaker: .me, start: 10.5, end: 14.5, text: "we ship the budget on friday"),
            MeetingSegment(speaker: .me, start: 20, end: 22, text: "Sounds good to me"),
        ]
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines)).map(\.text),
                       ["We ship the budget on Friday", "Sounds good to me"])
    }

    func testAnEchoIsCaughtEvenWhenTheLineItRepeatsIsJustOutsideTheTail() {
        // Asked for one line, the panel looks at the last three: two short
        // replies of yours and the echo of a line of theirs said just before.
        let lines = [
            MeetingSegment(speaker: .them, start: 0, end: 4, text: "The launch moves to March"),
            MeetingSegment(speaker: .me, start: 4.1, end: 4.5, text: "Okay one"),
            MeetingSegment(speaker: .me, start: 4.2, end: 4.6, text: "Okay two"),
            MeetingSegment(speaker: .me, start: 4.3, end: 6, text: "the launch moves to march"),
        ]
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines), count: 1).map(\.text), ["Okay two"])
    }

    func testLinesAreKeptOnOneLine() {
        let lines = [MeetingSegment(speaker: .me, start: 0, end: 2, text: "Two\nlines   here")]
        XCTAssertEqual(CallNotesPanel.recentLines(of: record(lines)).map(\.text), ["Two lines here"])
    }

    func testNothingSaidShowsNoLines() {
        XCTAssertEqual(CallNotesPanel.recentLines(of: record([])), [])
        XCTAssertEqual(CallNotesPanel.recentLines(of: record([
            MeetingSegment(speaker: .me, start: 0, end: 1, text: "Hi")]), count: 0), [])
    }

    // MARK: - Once the notes are ready

    func testNotesWithNothingInThemAreNotShown() {
        XCTAssertFalse(CallNotesPanel.hasNotes(nil))
        XCTAssertFalse(CallNotesPanel.hasNotes(MeetingNotes()))
        XCTAssertFalse(CallNotesPanel.hasNotes(MeetingNotes(summary: MeetingNotes.tooLittle)))
        XCTAssertTrue(CallNotesPanel.hasNotes(MeetingNotes(summary: "We agreed on the budget.")))
        XCTAssertTrue(CallNotesPanel.hasNotes(MeetingNotes(todos: [.init(text: "Book the room")])))
    }

    /// "Too little said" is the notes writer's own count: under it the
    /// writer is never asked, nothing is written, and the line says so
    /// instead of "Notes ready".
    func testUnderTheNotesWritersCountTooLittleWasSaid() {
        let few = MeetingNotes.minimumWords - 1
        XCTAssertEqual(CallNotesPanel.ready(words: 0, notes: nil), .tooLittleSaid)
        XCTAssertEqual(CallNotesPanel.ready(words: few, notes: nil), .tooLittleSaid)
        XCTAssertEqual(CallNotesPanel.ready(words: few, notes: MeetingNotes()), .tooLittleSaid)
        XCTAssertEqual(CallNotesPanel.ready(words: few, notes: MeetingNotes(summary: MeetingNotes.tooLittle)),
                       .tooLittleSaid)
        XCTAssertEqual(CallNotesPanel.tooLittleSaid, "Not enough was said for notes")
    }

    /// Enough said and still no notes (the notes writer off, or it failed):
    /// the page says why, so the line still points to it as ready.
    func testALongEnoughCallWithoutNotesIsStillReady() {
        XCTAssertEqual(CallNotesPanel.ready(words: MeetingNotes.minimumWords, notes: nil), .notes)
        XCTAssertEqual(CallNotesPanel.ready(words: 500, notes: MeetingNotes()), .notes)
        XCTAssertEqual(CallNotesPanel.ready(words: 500, notes: MeetingNotes(summary: "We agreed.")), .notes)
    }

    /// Notes that say something are ready however few words the transcript
    /// has: they can be written from another listening of the call.
    func testNotesThatSaySomethingAreReadyWhateverTheCount() {
        XCTAssertEqual(CallNotesPanel.ready(words: 3, notes: MeetingNotes(summary: "We agreed on the budget.")),
                       .notes)
        XCTAssertEqual(CallNotesPanel.ready(words: 0, notes: MeetingNotes(todos: [.init(text: "Book the room")])),
                       .notes)
    }

    /// A saved call's words are counted the way the notes writer counts
    /// them, and the line agrees with the page: where the page says nothing
    /// was heard or too little was said, the line says not enough was said.
    func testASavedCallReadsTheSameAsItsNotesPage() {
        for count in [0, 1, MeetingNotes.minimumWords - 1, MeetingNotes.minimumWords, 40] {
            let text = (0..<count).map { "word\($0)" }.joined(separator: " ")
            let call = record(count == 0 ? [] : [MeetingSegment(speaker: .them, start: 0, end: 9, text: text)])
            XCTAssertEqual(NumberedTranscript(call).wordCount, count)
            let page = MeetingFiles.notesPage(for: call, notes: nil)
            let pageSaysNone = page.contains(MeetingNotes.tooLittle) || page.contains("Nothing was heard")
            XCTAssertEqual(CallNotesPanel.ready(of: call, notes: nil) == .tooLittleSaid, pageSaysNone,
                           "\(count) words")
        }
    }

    // MARK: - The Mac notification

    private let madrid: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func ended(after minutes: Double) -> MeetingRecord {
        var call = record([MeetingSegment(speaker: .them, start: 0, end: 9, text: "Sobre el contrato de Jorge")],
                          with: ["Jorge"])
        call.endedAt = start.addingTimeInterval(minutes * 60)
        return call
    }

    /// When the call was and what is left to do: what tells two calls apart
    /// in the list the notification opens on.
    func testTheNotificationSaysWhenTheCallWasAndItsToDos() {
        XCTAssertEqual(CallNotesPanel.readyNotice(of: ended(after: 74), ready: .notes, todos: 3, calendar: madrid),
                       .init(title: "Call notes ready", body: "16:10–17:24 · 74 min · 3 to-dos"))
        XCTAssertEqual(CallNotesPanel.readyNotice(of: ended(after: 74), ready: .notes, todos: 1,
                                                  calendar: madrid)?.body,
                       "16:10–17:24 · 74 min · 1 to-do")
        XCTAssertEqual(CallNotesPanel.readyNotice(of: ended(after: 74), ready: .notes, todos: 0,
                                                  calendar: madrid)?.body,
                       "16:10–17:24 · 74 min")
    }

    /// It can land on a shared screen: nothing said in the call, its title
    /// (written from what was said) and the people in it included.
    func testTheNotificationCarriesNothingThatWasSaid() throws {
        var call = ended(after: 30)
        call.topic = "Contrato Jorge"
        let notice = try XCTUnwrap(CallNotesPanel.readyNotice(of: call, ready: .notes, todos: 2, calendar: madrid))
        for said in ["contrato", "Jorge", "Stand-up", "Zoom"] {
            XCTAssertFalse("\(notice.title) \(notice.body)".localizedCaseInsensitiveContains(said), said)
        }
    }

    /// Nothing was made when too little was said, so nothing is announced.
    func testNoNotificationWhenTooLittleWasSaid() {
        XCTAssertNil(CallNotesPanel.readyNotice(of: ended(after: 2), ready: .tooLittleSaid, todos: 0))
    }

    /// A call saved without its end still gets one, saying only what it can.
    func testACallWithoutItsEndStillGetsOne() {
        var call = ended(after: 10)
        call.endedAt = nil
        XCTAssertEqual(CallNotesPanel.readyNotice(of: call, ready: .notes, todos: 2)?.body, "2 to-dos")
        XCTAssertEqual(CallNotesPanel.readyNotice(of: call, ready: .notes, todos: 0)?.body, "Click to read them.")
    }

    func testTheSummaryIsCutAfterTwoSentences() {
        let summary = "The team went over the budget. Ana will send it by Friday. Bo asked about March."
        XCTAssertEqual(CallNotesPanel.summaryLead(summary),
                       "The team went over the budget. Ana will send it by Friday.")
    }

    func testAShortSummaryIsShownWhole() {
        XCTAssertEqual(CallNotesPanel.summaryLead("Only one sentence here."), "Only one sentence here.")
        XCTAssertEqual(CallNotesPanel.summaryLead("No full stop at all"), "No full stop at all")
        XCTAssertEqual(CallNotesPanel.summaryLead("One. Two."), "One. Two.")
        XCTAssertEqual(CallNotesPanel.summaryLead("   "), "")
    }

    func testTheSummaryCutKeepsQuestionsAndOtherScripts() {
        XCTAssertEqual(CallNotesPanel.summaryLead("Is it Friday? Yes it is! Then we ship."),
                       "Is it Friday? Yes it is!")
        XCTAssertEqual(CallNotesPanel.summaryLead("Hablamos del presupuesto. Ana lo envía el viernes. Fin."),
                       "Hablamos del presupuesto. Ana lo envía el viernes.")
    }

    func testTheSummaryCutKeepsItsLineTogether() {
        XCTAssertEqual(CallNotesPanel.summaryLead("First part\nstill the first. Second. Third."),
                       "First part still the first. Second.")
    }

    func testUpToThreeToDosAreListedWithTheirOwner() {
        let todos = CallNotesPanel.todos([
            .init(text: "Send the budget.", owner: "Ana"),
            .init(text: "Book the room"),
            .init(text: "Check the analytics", owner: "You"),
        ])
        XCTAssertEqual(todos.lines, ["Send the budget — Ana", "Book the room", "Check the analytics — You"])
        XCTAssertEqual(todos.more, 0)
        XCTAssertNil(todos.moreLine)
    }

    func testMoreThanThreeToDosSayHowManyMore() {
        let items = (1...5).map { MeetingNotes.Item(text: "Task \($0)") }
        let todos = CallNotesPanel.todos(items)
        XCTAssertEqual(todos.lines, ["Task 1", "Task 2", "Task 3"])
        XCTAssertEqual(todos.more, 2)
        XCTAssertEqual(todos.moreLine, "+2 more")
        XCTAssertEqual(CallNotesPanel.todos(Array(items.prefix(4))).moreLine, "+1 more")
    }

    func testNoToDosListNothing() {
        XCTAssertEqual(CallNotesPanel.todos([]), CallNotesPanel.Todos(lines: [], more: 0))
    }

    func testABlankOwnerIsNotShown() {
        XCTAssertEqual(CallNotesPanel.todos([.init(text: "Book the room", owner: "  ")]).lines,
                       ["Book the room"])
    }
}

final class MeetingRecordPauseFollowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testAPauseInTheNotesOpensOneInTheRecordWhereItBegan() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        XCTAssertTrue(record.followPause(since: at(40), now: at(41)))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 40)])
        XCTAssertTrue(record.isPaused)
    }

    func testFollowingTheSamePauseAgainChangesNothing() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.followPause(since: at(40), now: at(41))
        XCTAssertFalse(record.followPause(since: at(40), now: at(50)))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 40)])
    }

    func testAResumeClosesThePauseAtThatMoment() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.followPause(since: at(40), now: at(41))
        XCTAssertTrue(record.followPause(since: nil, now: at(95)))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 40, end: 95)])
        XCTAssertFalse(record.isPaused)
        XCTAssertFalse(record.followPause(since: nil, now: at(100)))
    }

    func testNotesThatEndWhilePausedCloseThePauseWhenTheyEnd() {
        var record = recordOfAFlow()
        // The flow leaves recording while paused: its pause is gone, and
        // the record's is closed at the moment the notes ended.
        var flow = MeetingNotesFlow(previewing: .recording(call, since: start), pausedSince: at(30))
        record.followPause(since: flow.pausedSince, now: at(31))
        _ = flow.apply(.stop, enabled: true, autoStart: false)
        XCTAssertNil(flow.pausedSince)
        record.followPause(since: flow.pausedSince, now: at(70))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 30, end: 70)])
    }

    func testAPauseFromBeforeTheRecordStartsAtItsStart() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.followPause(since: at(-2), now: at(1))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 0)])
    }

    func testASecondPauseFollowsTheFirst() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.followPause(since: at(10), now: at(10))
        record.followPause(since: nil, now: at(20))
        record.followPause(since: at(60), now: at(60))
        record.followPause(since: nil, now: at(65))
        XCTAssertEqual(record.pauses, [MeetingPause(start: 10, end: 20), MeetingPause(start: 60, end: 65)])
    }

    private let call = OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom",
                                   startedAt: Date(timeIntervalSince1970: 1_791_468_600))

    private func recordOfAFlow() -> MeetingRecord {
        MeetingRecord(bundleID: call.bundleID, appName: call.appName, startedAt: start)
    }
}

final class MeetingNotesFlowPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private let call = OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom",
                                   startedAt: Date(timeIntervalSince1970: 1_791_468_600))

    func testAPreviewStandsInTheGivenPhase() {
        let phases: [MeetingNotesFlow.Phase] = [
            .idle, .offering(call), .startingSoon(call, startsAt: now), .recording(call, since: now),
            .writing(call), .ready(folder: "f", call: call), .failed("x"),
        ]
        for phase in phases {
            XCTAssertEqual(MeetingNotesFlow(previewing: phase).phase, phase)
        }
    }

    func testOnlyRecordingCanBePreviewedPaused() {
        let paused = MeetingNotesFlow(previewing: .recording(call, since: now), pausedSince: now)
        XCTAssertEqual(paused.pausedSince, now)
        XCTAssertEqual(paused.pillMark(now: now, muted: false), .paused)
        XCTAssertNil(MeetingNotesFlow(previewing: .writing(call), pausedSince: now).pausedSince)
    }

    func testAPreviewedOfferIsSettledAndWaitsForAnEvent() {
        var flow = MeetingNotesFlow(previewing: .offering(call))
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .offer)
        XCTAssertFalse(flow.isWaitingForCallBack)
        XCTAssertEqual(flow.apply(.accept(at: now), enabled: true, autoStart: false),
                       [.startNotes(call, continuing: false)])
    }
}
