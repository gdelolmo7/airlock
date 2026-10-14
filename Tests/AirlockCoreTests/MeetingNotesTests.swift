import XCTest
@testable import AirlockCore

final class MeetingRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC

    func testSegmentsAreKeptInSpeakingOrderWhicheverTrackFinishesFirst() {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start)
        record.add(MeetingSegment(speaker: .them, start: 10, end: 14, text: "Second"))
        record.add(MeetingSegment(speaker: .me, start: 2, end: 5, text: "First"))
        record.add(MeetingSegment(speaker: .me, start: 20, end: 22, text: "Third"))
        XCTAssertEqual(record.segments.map(\.text), ["First", "Second", "Third"])
    }

    func testBlankSegmentsAreNotKept() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.add(MeetingSegment(speaker: .me, start: 0, end: 1, text: "  \n"))
        XCTAssertTrue(record.isEmpty)
    }

    func testTheMeetingServiceNamesABrowserCall() {
        let record = MeetingRecord(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                   site: .googleMeet, startedAt: start)
        XCTAssertEqual(record.callName, "Google Meet")
    }

    func testJotsAreTrimmedKeptInTimeOrderAndBlankOnesIgnored() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.jot("  second  ", at: 40)
        record.jot("first", at: 10)
        record.jot(" \n ", at: 20)
        XCTAssertEqual(record.jots, [MeetingJot(at: 10, text: "first"), MeetingJot(at: 40, text: "second")])
    }

    func testAMarkCoversTheHalfMinuteBeforeIt() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.mark(at: 100)
        XCTAssertEqual(MeetingRecord.markReach, 30)
        XCTAssertTrue(record.isMarked(MeetingSegment(speaker: .them, start: 75, end: 80, text: "x")))
        XCTAssertTrue(record.isMarked(MeetingSegment(speaker: .me, start: 60, end: 71, text: "x")),
                      "a turn that runs into the reach counts")
        XCTAssertTrue(record.isMarked(MeetingSegment(speaker: .me, start: 99, end: 110, text: "x")))
        XCTAssertFalse(record.isMarked(MeetingSegment(speaker: .me, start: 50, end: 69, text: "x")))
        XCTAssertFalse(record.isMarked(MeetingSegment(speaker: .me, start: 101, end: 105, text: "x")),
                       "what is said after the press is not what it was for")
    }

    func testPausingTwiceOpensOnePauseAndResumeClosesIt() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        XCTAssertFalse(record.isPaused)
        record.resume(at: 5)
        XCTAssertTrue(record.pauses.isEmpty, "nothing to resume")
        record.pause(at: 60)
        record.pause(at: 70)
        XCTAssertTrue(record.isPaused)
        XCTAssertEqual(record.pauses, [MeetingPause(start: 60)])
        record.resume(at: 130)
        XCTAssertFalse(record.isPaused)
        XCTAssertEqual(record.pauses, [MeetingPause(start: 60, end: 130)])
        record.pause(at: 200)
        record.resume(at: 190)
        XCTAssertEqual(record.pauses.last, MeetingPause(start: 200, end: 200), "never ends before it started")
    }

    func testTheOtherSideIsNamedOnlyOnAOneToOneCall() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        XCTAssertNil(record.otherName)
        XCTAssertEqual(record.label(for: .them), "Them")
        record.event = MeetingEvent(title: "Catch-up", start: start, attendees: [" Ana García "])
        XCTAssertEqual(record.otherName, "Ana García")
        XCTAssertEqual(record.label(for: .them), "Ana García")
        XCTAssertEqual(record.label(for: .me), "You")
        record.event?.attendees = ["Ana García", "Luis Pérez"]
        XCTAssertNil(record.otherName)
        XCTAssertEqual(record.label(for: .them), "Them")
    }

    /// A `meeting.json` from before events, jots, marks and pauses, exactly
    /// as the store wrote it. Those calls must still open.
    func testAnOlderRecordStillLoads() throws {
        let json = """
            {
              "appName" : "Zoom",
              "bundleID" : "us.zoom.xos",
              "endedAt" : "2026-10-08T14:52:00Z",
              "languages" : [
                "en-GB"
              ],
              "segments" : [
                {
                  "end" : 5,
                  "speaker" : "me",
                  "start" : 3,
                  "text" : "Hi, can you hear me?"
                }
              ],
              "site" : "zoom",
              "startedAt" : "2026-10-08T14:10:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.appName, "Zoom")
        XCTAssertEqual(record.site, .zoom)
        XCTAssertEqual(record.startedAt, start)
        XCTAssertEqual(record.endedAt, start.addingTimeInterval(42 * 60))
        XCTAssertEqual(record.languages, ["en-GB"])
        XCTAssertEqual(record.segments.map(\.text), ["Hi, can you hear me?"])
        XCTAssertNil(record.event)
        XCTAssertTrue(record.jots.isEmpty)
        XCTAssertTrue(record.marks.isEmpty)
        XCTAssertTrue(record.pauses.isEmpty)
    }

    func testEventJotsMarksAndPausesRoundTrip() throws {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start,
                                   event: MeetingEvent(title: "Budget", start: start, attendees: ["Ana"]))
        record.jot("Ask about Q3", at: 12)
        record.mark(at: 40)
        record.pause(at: 50)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: encoder.encode(record)), record)
    }
}

final class MeetingEchoTests: XCTestCase {
    func testTheirWordsPickedUpByTheMicrophoneAreDropped() {
        let segments = [
            MeetingSegment(speaker: .them, start: 10, end: 14, text: "Can we move the launch to Friday?"),
            MeetingSegment(speaker: .me, start: 10.4, end: 14.3, text: "can we move the launch to friday"),
            MeetingSegment(speaker: .me, start: 16, end: 18, text: "Yes, Friday works for me."),
        ]
        XCTAssertEqual(MeetingEcho.removingEchoes(from: segments).map(\.text),
                       ["Can we move the launch to Friday?", "Yes, Friday works for me."])
    }

    /// With headphones there is no echo, and both people really can say the
    /// same short thing at different moments.
    func testTheSameShortWordLaterIsNotAnEcho() {
        let segments = [
            MeetingSegment(speaker: .them, start: 10, end: 11, text: "Okay."),
            MeetingSegment(speaker: .me, start: 30, end: 31, text: "Okay."),
        ]
        XCTAssertEqual(MeetingEcho.removingEchoes(from: segments).count, 2)
    }

    func testAShortExactEchoAtTheSameMomentIsDropped() {
        let segments = [
            MeetingSegment(speaker: .them, start: 10, end: 11, text: "Thanks!"),
            MeetingSegment(speaker: .me, start: 10.3, end: 11.1, text: "thanks"),
        ]
        XCTAssertEqual(MeetingEcho.removingEchoes(from: segments).map(\.speaker), [.them])
    }

    func testAReplyThatSharesAFewWordsIsKept() {
        let segments = [
            MeetingSegment(speaker: .them, start: 10, end: 14, text: "Did you send the contract to the bank?"),
            MeetingSegment(speaker: .me, start: 14.5, end: 17, text: "Not yet, I will send it tomorrow morning"),
        ]
        XCTAssertEqual(MeetingEcho.removingEchoes(from: segments).count, 2)
    }

    func testAccentsAndCaseDoNotHideAnEcho() {
        let segments = [
            MeetingSegment(speaker: .them, start: 0, end: 3, text: "¿Qué hora es en Madrid ahora?"),
            MeetingSegment(speaker: .me, start: 0.2, end: 3.1, text: "que hora es en madrid ahora"),
        ]
        XCTAssertEqual(MeetingEcho.removingEchoes(from: segments).count, 1)
    }
}

final class MeetingFilesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC

    private func event(_ title: String, _ attendees: [String] = []) -> MeetingEvent {
        MeetingEvent(title: title, start: start, attendees: attendees)
    }

    /// Twenty-odd words, enough for notes.
    private var talk: [MeetingSegment] {
        [MeetingSegment(speaker: .them, start: 5, end: 12,
                        text: "Can you send the budget by Friday so we can close the quarter on time this month?"),
         MeetingSegment(speaker: .me, start: 13, end: 18, text: "Yes, I will send it on Thursday evening at the latest.")]
    }

    func testFolderNameSortsByDateAndAvoidsColons() {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start)
        XCTAssertEqual(MeetingFiles.folderName(for: record, timeZone: utc), "2026-10-08 14.10 – Zoom")
    }

    func testFolderNameCannotEscapeOrHide() {
        let record = MeetingRecord(bundleID: "x", appName: "../.Evil/App:Name", startedAt: start)
        let name = MeetingFiles.folderName(for: record, timeZone: utc)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("2026-10-08 14.10 – "))
    }

    func testAMeetingFromTheCalendarNamesTheFolderAndTheTitle() {
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   event: event("Q4 budget: final/review"))
        XCTAssertEqual(MeetingFiles.folderName(for: record, timeZone: utc),
                       "2026-10-08 14.10 – Q4 budget  final review")
        XCTAssertEqual(MeetingFiles.title(of: record), "Q4 budget: final/review")
    }

    func testAnEventWithoutATitleFallsBackToThePersonThenTheApp() {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   event: event("  ", ["Ana García"]))
        XCTAssertEqual(MeetingFiles.title(of: record), "Call with Ana García")
        XCTAssertEqual(MeetingFiles.folderName(for: record, timeZone: utc), "2026-10-08 14.10 – Zoom")
        record.event = nil
        XCTAssertEqual(MeetingFiles.title(of: record), "Call in Zoom")
    }

    /// The panel names a finished call by its event and app; the list names
    /// it by the saved record. One rule, so the two always say the same.
    func testTheTitleFromAnEventAndAppIsTheRecordsTitle() {
        let events: [MeetingEvent?] = [event("Weekly sync"), event("", ["Ana"]), event("  ", ["Ana", "Bo"]), nil]
        for event in events {
            let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, event: event)
            XCTAssertEqual(MeetingFiles.title(event: event, callName: record.callName),
                           MeetingFiles.title(of: record))
        }
        XCTAssertEqual(MeetingFiles.title(event: event("", ["Ana"]), callName: "FaceTime"), "Call with Ana")
        XCTAssertEqual(MeetingFiles.title(event: event("", ["Ana", "Bo"]), callName: "FaceTime"),
                       "Call in FaceTime")
        XCTAssertEqual(MeetingFiles.title(event: nil, callName: "FaceTime"), "Call in FaceTime")
    }

    func testTranscriptGroupsTurnsAndLabelsSpeakers() {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(42 * 60))
        record.add(MeetingSegment(speaker: .me, start: 3, end: 5, text: "Hi, can you hear me?"))
        record.add(MeetingSegment(speaker: .me, start: 6, end: 8, text: "I'm on the train."))
        record.add(MeetingSegment(speaker: .them, start: 9, end: 11, text: "Yes, loud and clear."))
        record.add(MeetingSegment(speaker: .me, start: 65, end: 70, text: "Great."))

        let text = MeetingFiles.transcript(of: record, timeZone: utc)
        XCTAssertTrue(text.hasPrefix("# Call in Zoom\n\n2026-10-08 14:10–14:52 · 42 min\n"))
        XCTAssertTrue(text.contains("**You** · 0:03  \nHi, can you hear me? I'm on the train.\n"))
        XCTAssertTrue(text.contains("**Them** · 0:09  \nYes, loud and clear.\n"))
        XCTAssertTrue(text.contains("**You** · 1:05  \nGreat.\n"))
    }

    func testOnAOneToOneCallTheTranscriptUsesTheirName() {
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start, segments: talk,
                                   event: event("Budget", ["Ana García"]))
        let text = MeetingFiles.transcript(of: record, timeZone: utc)
        XCTAssertTrue(text.hasPrefix("# Budget\n"))
        XCTAssertTrue(text.contains("**Ana García** · 0:05  \n"))
        XCTAssertFalse(text.contains("**Them**"))
    }

    func testTranscriptPutsNotesAndPausesWhereTheyHappened() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start, segments: talk)
        record.jot("Budget by Friday", at: 12)
        record.pause(at: 20)
        record.resume(at: 140)
        record.add(MeetingSegment(speaker: .me, start: 150, end: 152, text: "Back again."))
        record.pause(at: 200)

        let text = MeetingFiles.transcript(of: record, timeZone: utc)
        let order = ["**Them** · 0:05", "**Your note** · 0:12  \nBudget by Friday\n", "**You** · 0:13",
                     "_Paused 0:20–2:20_", "**You** · 2:30", "_Paused from 3:20_"]
        let positions = order.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(nil), text)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), text)
    }

    /// The file and the notes window say a pause the same way, closed or
    /// still on (`MeetingTimeline.pauseLabel`).
    func testTranscriptWordsAPauseAsTheWindowDoes() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start)
        record.pause(at: 723)
        record.resume(at: 845)
        record.pause(at: 3_600)

        let lines = MeetingFiles.transcript(of: record, timeZone: utc)
            .components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("_Paused 12:03–14:05_"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("_Paused from 1:00:00_"), lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("Paused at") })
        for pause in record.pauses {
            XCTAssertTrue(lines.contains("_\(MeetingTimeline.pauseLabel(pause))_"))
        }
    }

    func testTranscriptOfARunningCallSaysSo() {
        let record = MeetingRecord(bundleID: "a", appName: "FaceTime", startedAt: start)
        let text = MeetingFiles.transcript(of: record, timeZone: utc)
        XCTAssertTrue(text.contains("in progress"))
        XCTAssertTrue(text.contains("Nothing was heard yet."))
    }

    func testClockPastAnHour() {
        XCTAssertEqual(MeetingFiles.clock(65), "1:05")
        XCTAssertEqual(MeetingFiles.clock(3_729), "1:02:09")
    }

    func testNotesPageLeavesOutEmptyParts() {
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600), segments: talk)
        let notes = MeetingNotes(summary: "We agreed on Friday.",
                                 todos: [.init(text: "- Send the deck", sources: [1], at: 5)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)
        XCTAssertTrue(page.hasPrefix("# Notes: call in Zoom\n"))
        XCTAssertTrue(page.contains("## Summary\n\nWe agreed on Friday."))
        XCTAssertTrue(page.contains("## To-dos\n\n- [ ] Send the deck · 0:05\n"))
        for absent in ["## Your notes", "## Decisions", "## Open questions", "## Key points"] {
            XCTAssertFalse(page.contains(absent), absent)
        }
        XCTAssertTrue(page.contains("No audio was kept"))
    }

    func testNotesPageSectionsComeInOrderWithOwnersAndTimes() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600), segments: talk,
                                   event: event("Budget review", ["Ana García"]))
        record.jot("Ask   about\nQ3", at: 75)
        let notes = MeetingNotes(
            summary: "Ana needs the budget. You will send it Thursday.",
            todos: [.init(text: "Send the budget by Friday", owner: "You", sources: [2], at: 13),
                    .init(text: "Book the room — the big one", sources: [1], at: 5)],
            decisions: [.init(text: "Close the quarter on time", sources: [1], at: 5)],
            questions: [.init(text: "Who signs it off?", sources: [2], at: 3_729)],
            keyPoints: [.init(text: "The quarter closes this month", sources: [1], at: 5)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)

        XCTAssertTrue(page.hasPrefix("# Notes: Budget review\n"), "the meeting's name keeps its capitals")
        let sections = ["## Summary", "## Your notes", "## To-dos", "## Decisions", "## Open questions", "## Key points"]
        let positions = sections.map { page.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(nil), page)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(page.contains("- Ask about Q3 · 1:15\n"))
        XCTAssertTrue(page.contains("- [ ] Send the budget by Friday — You · 0:13\n"))
        XCTAssertTrue(page.contains("- [ ] Book the room – the big one · 0:05\n"), "a dash in the text is softened")
        XCTAssertTrue(page.contains("- Close the quarter on time · 0:05\n"))
        XCTAssertTrue(page.contains("- Who signs it off? · 1:02:09\n"))
        XCTAssertTrue(page.contains("- The quarter closes this month · 0:05\n"))
    }

    func testNotesPageWithoutASummaryPointsAtTheTranscript() {
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600), segments: talk)
        let page = MeetingFiles.notesPage(for: record, notes: nil,
                                          unavailableReason: "Apple Intelligence is off", timeZone: utc)
        XCTAssertTrue(page.contains("No summary this time: Apple Intelligence is off"))
        XCTAssertTrue(page.contains("Transcript.md"))
    }

    /// A long call's last stretch failed: the page says which minutes,
    /// right under the summary that was written without them.
    func testNotesPageNamesTheMinutesWithNoNotes() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(2_700), segments: talk)
        record.jot("budget", at: 20)
        let notes = MeetingNotes(summary: "We agreed on Friday.",
                                 todos: [.init(text: "Send the deck", sources: [1], at: 5)],
                                 unwritten: [.init(start: 1_930, end: 2_645), .init(start: 3_600, end: 3_729)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)
        XCTAssertTrue(page.contains("""
            ## Summary

            We agreed on Friday.

            _Couldn't write notes for 32:10–44:05. The transcript has it all._

            _Couldn't write notes for 1:00:00–1:02:09. The transcript has it all._

            ## Your notes
            """), page)

        let withoutSummary = MeetingFiles.notesPage(
            for: record, notes: MeetingNotes(todos: notes.todos, unwritten: notes.unwritten), timeZone: utc)
        XCTAssertTrue(withoutSummary.contains("2026-10-08 14:10–14:55 · 45 min\n\n_Couldn't write notes for 32:10"),
                      withoutSummary)
        XCTAssertFalse(MeetingFiles.notesPage(for: record, notes: MeetingNotes(summary: "Fine."), timeZone: utc)
            .contains("Couldn't write notes"))
    }

    func testNotesPageSaysWhenTooLittleOrNothingWasSaid() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(60))
        XCTAssertTrue(MeetingFiles.notesPage(for: record, notes: nil, timeZone: utc)
            .contains("Nothing was heard on this call"))
        record.add(MeetingSegment(speaker: .me, start: 1, end: 3, text: "Hello? Can you hear me?"))
        record.jot("call back later", at: 30)
        let page = MeetingFiles.notesPage(for: record, notes: MeetingNotes(), timeZone: utc)
        XCTAssertTrue(page.contains("Too little was said on this call for notes."))
        XCTAssertTrue(page.contains("## Your notes\n\n- call back later · 0:30"), "their own notes are kept")
        XCTAssertFalse(page.contains("No summary this time"))
    }
}

final class MeetingNotesTidyTests: XCTestCase {
    func testStretchesWithNoNotesAreKeptInOrderAndJoinedWhereTheyMeet() {
        let notes = MeetingNotes(unwritten: [.init(start: 2_290, end: 2_645), .init(start: 1_930, end: 2_290),
                                             .init(start: 60, end: 120)])
        XCTAssertEqual(notes.unwritten, [.init(start: 60, end: 120), .init(start: 1_930, end: 2_645)])
        XCTAssertTrue(notes.isEmpty, "what is missing is not something said")
        XCTAssertEqual(notes.unwritten[1].sentence, "Couldn't write notes for 32:10–44:05. The transcript has it all.")
    }


    /// Measured: the on-device model listed "Reservar vuelos esta noche."
    /// under both decisions and to-dos.
    func testATaskFiledAsADecisionTooIsKeptOnlyAsATask() {
        let notes = MeetingNotes(todos: [.init(text: "book flights tonight"), .init(text: "Find a hotel")],
                                 decisions: [.init(text: "Book flights tonight."), .init(text: "Yearly plan as default")])
        XCTAssertEqual(notes.decisions.map(\.text), ["Yearly plan as default"])
        XCTAssertEqual(notes.todos.map(\.text), ["book flights tonight", "Find a hotel"])
    }

    func testRepeatsAreKeptOnceAndALaterOwnerIsNotLost() {
        let notes = MeetingNotes(todos: [.init(text: "Send the deck", sources: [3]),
                                         .init(text: "send the deck!", owner: "Ana", sources: [9])])
        XCTAssertEqual(notes.todos, [.init(text: "Send the deck", owner: "Ana", sources: [3])])
    }

    func testAKeyPointThatRepeatsAnotherLineIsDropped() {
        let notes = MeetingNotes(questions: [.init(text: "Who pays for the venue?")],
                                 keyPoints: [.init(text: "who pays for the venue"), .init(text: "Venue is booked")])
        XCTAssertEqual(notes.keyPoints.map(\.text), ["Venue is booked"])
    }

    func testLinesAreCleanedOfBulletsBoxesAndCitations() {
        XCTAssertEqual(MeetingText.clean("- [ ] Send the deck (S12)"), "Send the deck")
        XCTAssertEqual(MeetingText.clean("• Ship   on\nMonday [S3, S4]."), "Ship on Monday.")
        XCTAssertEqual(MeetingText.key("Ship on Monday."), MeetingText.key("ship, on monday"))
        XCTAssertNotEqual(MeetingText.key("Ship on Monday"), MeetingText.key("Ship on Tuesday"))
    }
}

/// The calls here are short, and the rules they test are not about length:
/// they keep notes of any length (`keepingFrom: 0`). The shortest kept has
/// its own tests, `MeetingNotesShortCallTests`.
final class MeetingNotesFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private func call(_ id: String = "us.zoom.xos") -> OngoingCall {
        OngoingCall(bundleID: id, appName: "Zoom", startedAt: now)
    }

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// Notes being taken on `call()` since `now`.
    private func recording() -> MeetingNotesFlow {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        return flow
    }

    private func tick(_ flow: inout MeetingNotesFlow, _ seconds: TimeInterval, onMic: Bool? = nil,
                      spoke: TimeInterval? = nil, theySpoke: TimeInterval? = nil) -> [MeetingNotesFlow.Effect] {
        flow.apply(.tick(.init(now: at(seconds), callOnMic: onMic, lastSpeech: spoke.map(at),
                               theirLastSpeech: theySpoke.map(at))),
                   enabled: true, autoStart: false)
    }

    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: true, autoStart: false)
    }

    func testSwitchedOffNothingHappens() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(flow.apply(.callStarted(call(), at: now), enabled: false, autoStart: true), [])
        XCTAssertEqual(flow.phase, .idle)
    }

    func testACallIsOfferedAndTakesNotesOnlyAfterYes() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.phase, .offering(call()))
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .ask)

        let effects = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        XCTAssertEqual(effects, [.startNotes(call(), continuing: false)])
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .recording)

        XCTAssertEqual(flow.apply(.callEnded(at: at(60)), enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.apply(.tick(.init(now: at(65), callOnMic: false)),
                                  enabled: true, autoStart: false), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
        _ = flow.apply(.saved(folder: "2026-10-08 14.10 – Zoom"), enabled: true, autoStart: false)
        XCTAssertEqual(flow.phase, .ready(folder: "2026-10-08 14.10 – Zoom", call: call()))
    }

    func testAlwaysIsRememberedAndLaterCallsStartOnTheirOwn() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        XCTAssertEqual(flow.apply(.acceptAlways(at: now), enabled: true, autoStart: false),
                       [.rememberAlways, .startNotes(call(), continuing: false)])

        var next = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(next.apply(.callStarted(call("com.apple.FaceTime"), at: now),
                                  enabled: true, autoStart: true), [])
        XCTAssertEqual(next.phase, .startingSoon(call("com.apple.FaceTime"), startsAt: at(3)))
        XCTAssertEqual(next.apply(.accept(at: at(3)), enabled: true, autoStart: true),
                       [.startNotes(call("com.apple.FaceTime"), continuing: false)])
        XCTAssertEqual(next.phase, .recording(call("com.apple.FaceTime"), since: at(3)))
    }

    func testDecliningForgetsTheCallAndAnUnansweredOfferEndsWithIt() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.decline, enabled: true, autoStart: false)
        XCTAssertEqual(flow.phase, .idle)

        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        XCTAssertEqual(flow.apply(.callEnded(at: now), enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.phase, .idle)
    }

    func testACallThatDropsAndComesBackIsTheSameMeeting() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        _ = flow.apply(.callEnded(at: now.addingTimeInterval(600)), enabled: true, autoStart: false)
        XCTAssertEqual(flow.apply(.tick(.init(now: at(606), callOnMic: false)),
                                  enabled: true, autoStart: false), [.finishNotes])

        let back = flow.apply(.callStarted(call(), at: now.addingTimeInterval(650)),
                              enabled: true, autoStart: false)
        XCTAssertEqual(back, [.startNotes(call(), continuing: true)])
    }

    func testAMuchLaterCallIsANewMeetingAndIsAskedAbout() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        _ = flow.apply(.callEnded(at: now.addingTimeInterval(600)), enabled: true, autoStart: false)
        _ = flow.apply(.tick(.init(now: at(606), callOnMic: false)), enabled: true, autoStart: false)
        _ = flow.apply(.saved(folder: "f"), enabled: true, autoStart: false)

        XCTAssertEqual(flow.apply(.callStarted(call(), at: now.addingTimeInterval(1_200)),
                                  enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.phase, .offering(call()))
    }

    func testStoppingByHandIsNotResumedWhenTheCallFlickers() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        XCTAssertEqual(flow.apply(.stop, enabled: true, autoStart: false), [.finishNotes])
        XCTAssertEqual(flow.apply(.callEnded(at: now), enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.apply(.callStarted(call(), at: now.addingTimeInterval(5)),
                                  enabled: true, autoStart: false), [])
        XCTAssertEqual(flow.phase, .offering(call()))
    }

    func testANewCallsOfferIsNotReplacedByAnOldCallsNotes() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: false)
        _ = flow.apply(.accept(at: now), enabled: true, autoStart: false)
        _ = flow.apply(.callEnded(at: now), enabled: true, autoStart: false)
        _ = flow.apply(.callStarted(call("com.apple.FaceTime"), at: now.addingTimeInterval(5)),
                       enabled: true, autoStart: false)
        _ = flow.apply(.saved(folder: "old"), enabled: true, autoStart: false)
        XCTAssertEqual(flow.phase, .offering(call("com.apple.FaceTime")))
    }

    // MARK: Stopping

    func testTheNotesStopOnlyOnceTheMicHasBeenLetGoForFiveSeconds() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .callEnded(at: at(100))), [])
        XCTAssertTrue(flow.isWaitingForCallBack)
        XCTAssertEqual(tick(&flow, 103, onMic: false, spoke: 99), [])
        XCTAssertEqual(tick(&flow, 104.9, onMic: false, spoke: 99), [])
        XCTAssertEqual(flow.pillMark(now: at(104.9), muted: false), .recording)
        XCTAssertEqual(tick(&flow, 105, onMic: false, spoke: 99), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
    }

    func testTheSameCallBackInsideTheWaitChangesNothing() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(103))), [])
        XCTAssertEqual(flow.phase, .recording(call(), since: now))
        XCTAssertFalse(flow.isWaitingForCallBack)
        XCTAssertEqual(tick(&flow, 200, spoke: 199), [])
    }

    /// The detector needs the call app playing and a settle before it says a
    /// call is back; the microphone itself says so sooner.
    func testTheCallAppBackOnTheMicKeepsTheNotesUntilItLetsGoAgain() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(tick(&flow, 102, onMic: true, spoke: 101), [])
        XCTAssertEqual(tick(&flow, 300, onMic: true, spoke: 299), [])
        XCTAssertEqual(flow.phase, .recording(call(), since: now))
        // Lets go again, with no word from the detector this time.
        XCTAssertEqual(tick(&flow, 301, onMic: false, spoke: 299), [])
        XCTAssertEqual(tick(&flow, 305.9, onMic: false, spoke: 299), [])
        XCTAssertEqual(tick(&flow, 306, onMic: false, spoke: 299), [.finishNotes])
    }

    func testNoAutomaticStopBeforeThirtySecondsOfNotes() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(3)))
        XCTAssertEqual(tick(&flow, 10, onMic: false), [])
        XCTAssertEqual(tick(&flow, 29.9, onMic: false), [])
        XCTAssertEqual(tick(&flow, 30, onMic: false), [.finishNotes])
    }

    func testAnEarlyEndThatIsOverByTheThirtySecondMarkIsForgotten() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(3)))
        XCTAssertEqual(tick(&flow, 20, onMic: true), [])
        XCTAssertEqual(tick(&flow, 30, onMic: true), [])
        XCTAssertEqual(tick(&flow, 60, onMic: true, spoke: 59), [])
        XCTAssertEqual(flow.pillMark(now: at(60), muted: false), .recording)
    }

    func testTheCallAppQuittingStopsTheNotesTenSecondsLater() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .appQuit(bundleID: call().bundleID, at: at(100))), [])
        XCTAssertEqual(send(&flow, .callEnded(at: at(100))), [])
        XCTAssertEqual(tick(&flow, 105, onMic: false, spoke: 99), [])
        XCTAssertEqual(tick(&flow, 109.9, onMic: false, spoke: 99), [])
        XCTAssertEqual(tick(&flow, 110, onMic: false, spoke: 99), [.finishNotes])
    }

    func testACallAppReopenedAndBackOnTheCallKeepsTheNotes() {
        var flow = recording()
        _ = send(&flow, .appQuit(bundleID: call().bundleID, at: at(100)))
        XCTAssertEqual(tick(&flow, 107, onMic: true, spoke: 106), [])
        XCTAssertEqual(tick(&flow, 130, onMic: true, spoke: 129), [])
        XCTAssertEqual(flow.phase, .recording(call(), since: now))
    }

    func testAnotherAppQuittingChangesNothing() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .appQuit(bundleID: "com.spotify.client", at: at(100))), [])
        XCTAssertFalse(flow.isWaitingForCallBack)
        XCTAssertEqual(tick(&flow, 200, spoke: 199), [])
    }

    func testFifteenMinutesWithNobodySpeakingStopTheNotes() {
        var flow = recording()
        XCTAssertEqual(tick(&flow, 899), [])
        XCTAssertEqual(tick(&flow, 900), [.finishNotes])

        var talked = recording()
        XCTAssertEqual(tick(&talked, 900, spoke: 600), [])
        XCTAssertEqual(tick(&talked, 1_499, spoke: 600), [])
        XCTAssertEqual(tick(&talked, 1_500, spoke: 600), [.finishNotes])
    }

    func testTheMacGoingToSleepStopsTheNotesAndTheCallCanCarryOnAfter() {
        var flow = recording()
        // Not held to the thirty seconds: asleep, there is nothing to wait on.
        XCTAssertEqual(send(&flow, .sleep(at: at(10))), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(70))),
                       [.startNotes(call(), continuing: true)])
    }

    /// The Mac wakes a minute after the sleep stopped the notes and the call
    /// is still on: the model says the call started (the detector never saw
    /// it end), and the notes carry on in the same folder.
    func testAWakeWithTheCallStillOnCarriesOnTheSameNotes() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .sleep(at: at(100))), [.finishNotes])
        // Before the summary is even saved.
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(160))),
                       [.startNotes(call(), continuing: true)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(160)))
        // The detector saying so as well changes nothing.
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(161))), [])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(160)))
    }

    /// Ten minutes asleep is past the same-meeting window: asked again.
    func testAWakeLongAfterTheSleepAsksAboutTheCallAgain() {
        var flow = recording()
        _ = send(&flow, .sleep(at: at(100)))
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(700))), [])
        XCTAssertEqual(flow.phase, .offering(call()))
    }

    /// The same, with "Always": new notes, in a new folder, after the
    /// countdown.
    func testAWakeLongAfterTheSleepWithAlwaysStartsNewNotes() {
        var flow = recording()
        _ = send(&flow, .sleep(at: at(100)))
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(flow.apply(.callStarted(call(), at: at(700)), enabled: true, autoStart: true), [])
        XCTAssertEqual(flow.phase, .startingSoon(call(), startsAt: at(703)))
        XCTAssertEqual(flow.apply(.accept(at: at(703)), enabled: true, autoStart: true),
                       [.startNotes(call(), continuing: false)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(703)))
    }

    /// The waits are dates, and a date keeps counting while the Mac sleeps:
    /// the first look after an hour asleep sees an hour, not a second.
    func testAWaitThatRanOutWhileTheMacSleptEndsOnTheFirstLookAfter() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(tick(&flow, 101, onMic: false, spoke: 99), [])
        XCTAssertEqual(tick(&flow, 3_700, onMic: false, spoke: 99), [.finishNotes])
    }

    func testTheOtherSideStillTalkingHoldsTheStop() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(tick(&flow, 106, onMic: false, spoke: 105, theySpoke: 105), [])
        XCTAssertEqual(tick(&flow, 120, onMic: false, spoke: 119, theySpoke: 119), [])
        XCTAssertEqual(tick(&flow, 124, onMic: false, spoke: 119, theySpoke: 119), [.finishNotes])
    }

    /// A browser plays a video after the call just as it played the call.
    func testTalkingHoldsTheStopForAQuarterOfAnHourAtMost() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(tick(&flow, 999, onMic: false, spoke: 998, theySpoke: 998), [])
        XCTAssertEqual(tick(&flow, 1_000, onMic: false, spoke: 999, theySpoke: 999), [.finishNotes])
    }

    func testStoppingByHandStillWorksWhileWaiting() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(send(&flow, .stop), [.finishNotes])
        XCTAssertFalse(flow.isWaitingForCallBack)
        XCTAssertEqual(tick(&flow, 200, onMic: false), [])
        // Stopped by hand, so the same call coming back is asked about again.
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(201))), [])
        XCTAssertEqual(flow.phase, .offering(call()))
    }

    func testAnotherAppsCallFinishesTheFirstCallsNotes() {
        var flow = recording()
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(send(&flow, .callStarted(call("com.apple.FaceTime"), at: at(101))), [.finishNotes])
        XCTAssertEqual(flow.phase, .offering(call("com.apple.FaceTime")))
        XCTAssertFalse(flow.isWaitingForCallBack)
    }

    func testLooksAndQuitsOutsideNotesDoNothing() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(tick(&flow, 2_000), [])
        XCTAssertEqual(send(&flow, .appQuit(bundleID: call().bundleID, at: at(1))), [])
        XCTAssertEqual(send(&flow, .sleep(at: at(1))), [])
        XCTAssertEqual(flow.phase, .idle)
    }

    // MARK: The ask

    func testTheAskSaysNotesForTenSecondsThenSettlesToADot() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = send(&flow, .callStarted(call(), at: now))
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .ask)
        XCTAssertEqual(flow.pillMark(now: at(9.9), muted: true), .ask)
        XCTAssertEqual(flow.pillMark(now: at(10), muted: false), .offer)
        XCTAssertEqual(flow.pillMark(now: at(600), muted: false), .offer)
        // A clock set back does not bring the word back for long.
        XCTAssertEqual(flow.pillMark(now: at(-1), muted: false), .offer)
    }

    func testEachNewOfferAsksAgain() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = send(&flow, .callStarted(call(), at: now))
        _ = send(&flow, .callStarted(call("com.apple.FaceTime"), at: at(60)))
        XCTAssertEqual(flow.pillMark(now: at(65), muted: false), .ask)
        XCTAssertEqual(flow.pillMark(now: at(70), muted: false), .offer)
    }

    func testNoMarkWithoutAnOfferOrNotes() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(flow.pillMark(now: now, muted: true), .none)
        _ = send(&flow, .callStarted(call(), at: now))
        _ = send(&flow, .decline)
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .none)

        var writing = recording()
        _ = send(&writing, .stop)
        XCTAssertEqual(writing.pillMark(now: at(1), muted: true), .none)
    }

    // MARK: The countdown

    func testAlwaysCountsDownThreeSecondsBeforeTheNotesStart() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: true), [])
        XCTAssertEqual(flow.phase, .startingSoon(call(), startsAt: at(MeetingNotesFlow.countdown)))
        XCTAssertEqual(flow.pillMark(now: at(1), muted: false), .startingSoon(at(3)))
        XCTAssertEqual(flow.apply(.accept(at: at(3)), enabled: true, autoStart: true),
                       [.startNotes(call(), continuing: false)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(3)))
    }

    /// "Start now" is the same accept, sooner.
    func testTheCountdownCanBeCutShort() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(flow.apply(.accept(at: at(1)), enabled: true, autoStart: true),
                       [.startNotes(call(), continuing: false)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(1)))
    }

    func testSkippingTheCountdownLeavesTheOfferSettled() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(flow.apply(.decline, enabled: true, autoStart: true), [])
        XCTAssertEqual(flow.phase, .offering(call()))
        // The dot at once, not "Notes?": it was just answered.
        XCTAssertEqual(flow.pillMark(now: at(1), muted: false), .offer)
        // A change of mind later in the call still takes notes.
        XCTAssertEqual(flow.apply(.accept(at: at(300)), enabled: true, autoStart: true),
                       [.startNotes(call(), continuing: false)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(300)))
    }

    func testTheCountdownEndsWithTheCall() {
        var ended = MeetingNotesFlow(keepingFrom: 0)
        _ = ended.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(ended.apply(.callEnded(at: at(1)), enabled: true, autoStart: true), [])
        XCTAssertEqual(ended.phase, .idle)

        var quit = MeetingNotesFlow(keepingFrom: 0)
        _ = quit.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(quit.apply(.appQuit(bundleID: "com.spotify.client", at: at(1)),
                                  enabled: true, autoStart: true), [])
        XCTAssertEqual(quit.phase, .startingSoon(call(), startsAt: at(3)))
        XCTAssertEqual(quit.apply(.appQuit(bundleID: call().bundleID, at: at(1)),
                                  enabled: true, autoStart: true), [])
        XCTAssertEqual(quit.phase, .idle)

        var asleep = MeetingNotesFlow(keepingFrom: 0)
        _ = asleep.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(asleep.apply(.sleep(at: at(1)), enabled: true, autoStart: true), [])
        XCTAssertEqual(asleep.phase, .idle)
    }

    func testAnotherAppsCallReplacesTheCountdown() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(flow.apply(.callStarted(call("com.apple.FaceTime"), at: at(2)),
                                  enabled: true, autoStart: true), [])
        XCTAssertEqual(flow.phase, .startingSoon(call("com.apple.FaceTime"), startsAt: at(5)))
    }

    func testTheSameCallSaidTwiceKeepsItsCountdown() {
        var flow = MeetingNotesFlow(keepingFrom: 0)
        _ = flow.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(flow.apply(.callStarted(call(), at: at(2)), enabled: true, autoStart: true), [])
        XCTAssertEqual(flow.phase, .startingSoon(call(), startsAt: at(3)))
    }

    /// A call that comes straight back is the same meeting: no countdown.
    func testACallThatComesBackCarriesOnAtOnceWithAlways() {
        var flow = recording()
        _ = send(&flow, .sleep(at: at(100)))
        XCTAssertEqual(flow.apply(.callStarted(call(), at: at(130)), enabled: true, autoStart: true),
                       [.startNotes(call(), continuing: true)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(130)))
    }

    // MARK: Pausing

    func testNotesCanBePausedAndResumed() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .pause(at: at(60))), [.pauseNotes])
        XCTAssertEqual(flow.pausedSince, at(60))
        XCTAssertEqual(flow.phase, .recording(call(), since: now))
        XCTAssertEqual(flow.pillMark(now: at(61), muted: false), .paused)

        XCTAssertEqual(send(&flow, .resume(at: at(90))), [.resumeNotes])
        XCTAssertNil(flow.pausedSince)
        XCTAssertEqual(flow.pillMark(now: at(91), muted: false), .recording)
    }

    func testPausingTwiceOrResumingUnpausedNotesChangesNothing() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .resume(at: at(10))), [])
        _ = send(&flow, .pause(at: at(20)))
        XCTAssertEqual(send(&flow, .pause(at: at(30))), [])
        XCTAssertEqual(flow.pausedSince, at(20))
        _ = send(&flow, .resume(at: at(40)))
        XCTAssertEqual(send(&flow, .resume(at: at(50))), [])
    }

    func testPauseOnlyMeansSomethingWhileTakingNotes() {
        var idle = MeetingNotesFlow(keepingFrom: 0)
        XCTAssertEqual(send(&idle, .pause(at: now)), [])
        XCTAssertNil(idle.pausedSince)

        var offering = MeetingNotesFlow(keepingFrom: 0)
        _ = send(&offering, .callStarted(call(), at: now))
        XCTAssertEqual(send(&offering, .pause(at: at(1))), [])
        XCTAssertNil(offering.pausedSince)

        var soon = MeetingNotesFlow(keepingFrom: 0)
        _ = soon.apply(.callStarted(call(), at: now), enabled: true, autoStart: true)
        XCTAssertEqual(soon.apply(.pause(at: at(1)), enabled: true, autoStart: true), [])
        XCTAssertNil(soon.pausedSince)
    }

    func testPausedOutranksMuted() {
        var flow = recording()
        XCTAssertEqual(flow.pillMark(now: at(5), muted: true), .muted)
        _ = send(&flow, .pause(at: at(10)))
        XCTAssertEqual(flow.pillMark(now: at(11), muted: true), .paused)
        _ = send(&flow, .resume(at: at(20)))
        XCTAssertEqual(flow.pillMark(now: at(21), muted: true), .muted)
    }

    func testAPauseIsNotSilence() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(10)))
        XCTAssertEqual(tick(&flow, 3_000), [])
        XCTAssertEqual(flow.phase, .recording(call(), since: now))
        // Counted from the resume, not from the last word before the pause.
        _ = send(&flow, .resume(at: at(3_000)))
        XCTAssertEqual(tick(&flow, 3_899, spoke: 5), [])
        XCTAssertEqual(tick(&flow, 3_900, spoke: 5), [.finishNotes])
    }

    func testSpeechAfterTheResumeStillPutsTheSilenceOff() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(10)))
        _ = send(&flow, .resume(at: at(100)))
        XCTAssertEqual(tick(&flow, 1_000, spoke: 400), [])
        XCTAssertEqual(tick(&flow, 1_299, spoke: 400), [])
        XCTAssertEqual(tick(&flow, 1_300, spoke: 400), [.finishNotes])
    }

    func testACallEndingStillStopsPausedNotes() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(40)))
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(tick(&flow, 104, onMic: false), [])
        XCTAssertEqual(tick(&flow, 105, onMic: false), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
        XCTAssertNil(flow.pausedSince)
    }

    func testStoppingPausedNotesWritesThem() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(40)))
        XCTAssertEqual(send(&flow, .stop), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
        XCTAssertNil(flow.pausedSince)
        XCTAssertEqual(send(&flow, .resume(at: at(50))), [])
    }

    func testTheNextNotesStartUnpaused() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(40)))
        _ = send(&flow, .sleep(at: at(100)))
        XCTAssertNil(flow.pausedSince)
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(130))),
                       [.startNotes(call(), continuing: true)])
        XCTAssertNil(flow.pausedSince)
        XCTAssertEqual(flow.pillMark(now: at(131), muted: false), .recording)

        var failed = recording()
        _ = send(&failed, .pause(at: at(40)))
        _ = send(&failed, .failed("No microphone"))
        XCTAssertNil(failed.pausedSince)
    }

    /// The same call said again while paused is the same notes, still paused.
    func testTheSameCallBackKeepsThePause() {
        var flow = recording()
        _ = send(&flow, .pause(at: at(40)))
        _ = send(&flow, .callEnded(at: at(100)))
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(102))), [])
        XCTAssertEqual(flow.pausedSince, at(40))
    }

    // MARK: The heads-up

    /// The heads-up counts from the first start of the call's notes. A pause,
    /// or notes carried on after the Mac slept, are the same call: its
    /// people were told already, so the minute does not start again.
    func testTheHeadsUpIsOfferedOncePerCall() throws {
        var flow = recording()
        XCTAssertEqual(flow.firstStarted, now)
        XCTAssertTrue(CallNotesPanel.showsHeadsUp(notesSince: try XCTUnwrap(flow.firstStarted), now: at(30)))

        _ = send(&flow, .pause(at: at(40)))
        _ = send(&flow, .resume(at: at(70)))
        XCTAssertEqual(flow.firstStarted, now)
        XCTAssertFalse(CallNotesPanel.showsHeadsUp(notesSince: try XCTUnwrap(flow.firstStarted), now: at(71)))

        // Asleep and awake again mid-call: carried on, with a new `since`.
        _ = send(&flow, .sleep(at: at(100)))
        XCTAssertNil(flow.firstStarted)
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(160))),
                       [.startNotes(call(), continuing: true)])
        XCTAssertEqual(flow.phase, .recording(call(), since: at(160)))
        XCTAssertEqual(flow.firstStarted, now)
        XCTAssertFalse(CallNotesPanel.showsHeadsUp(notesSince: try XCTUnwrap(flow.firstStarted), now: at(161)))

        // Dropped and back once more: still the first start.
        _ = send(&flow, .callEnded(at: at(400)))
        XCTAssertEqual(tick(&flow, 405, onMic: false), [.finishNotes])
        _ = send(&flow, .callStarted(call(), at: at(420)))
        XCTAssertEqual(flow.firstStarted, now)
    }

    /// Notes carried on inside the first minute keep what is left of it.
    func testNotesCarriedOnEarlyKeepTheRestOfTheMinute() {
        var flow = recording()
        _ = send(&flow, .sleep(at: at(10)))
        _ = send(&flow, .callStarted(call(), at: at(40)))
        XCTAssertEqual(flow.firstStarted, now)
        XCTAssertTrue(CallNotesPanel.showsHeadsUp(notesSince: now, now: at(45)))
        XCTAssertFalse(CallNotesPanel.showsHeadsUp(notesSince: now, now: at(60)))
    }

    /// New notes are a new start: a call long after, or one asked about
    /// again after "Stop", has its own minute.
    func testNewNotesStartTheirOwnMinute() {
        var later = recording()
        _ = send(&later, .sleep(at: at(100)))
        _ = send(&later, .saved(folder: "f"))
        _ = send(&later, .callStarted(call(), at: at(700)))
        XCTAssertNil(later.firstStarted)
        _ = send(&later, .accept(at: at(705)))
        XCTAssertEqual(later.firstStarted, at(705))

        var stopped = recording()
        _ = send(&stopped, .stop)
        XCTAssertNil(stopped.firstStarted)
        _ = send(&stopped, .callStarted(call(), at: at(201)))
        _ = send(&stopped, .accept(at: at(202)))
        XCTAssertEqual(stopped.firstStarted, at(202))
    }

    func testAPreviewedRecordingStartedAtItsSince() {
        let flow = MeetingNotesFlow(previewing: .recording(call(), since: at(-25)))
        XCTAssertEqual(flow.firstStarted, at(-25))
        XCTAssertNil(MeetingNotesFlow(previewing: .offering(call())).firstStarted)
    }
}

final class MeetingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFilesArePrivateAndReadBack() throws {
        let store = MeetingStore(root: root)
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom",
                                   startedAt: Date(timeIntervalSince1970: 1_791_468_600))
        record.add(MeetingSegment(speaker: .me, start: 1, end: 2, text: "Hello"))
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)

        let manager = FileManager.default
        for name in [MeetingFiles.recordName, MeetingFiles.transcriptName] {
            let path = folder.appendingPathComponent(name).path
            let mode = try manager.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
        let folderMode = try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        XCTAssertEqual(store.loadRecord(in: folder), record)
    }

    func testTwoCallsInTheSameMinuteGetTwoFolders() throws {
        let store = MeetingStore(root: root)
        let record = MeetingRecord(bundleID: "a", appName: "Zoom",
                                   startedAt: Date(timeIntervalSince1970: 1_791_468_600))
        let first = try store.makeFolder(for: record)
        let second = try store.makeFolder(for: record)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2"))
    }

    func testAFolderLeftWithoutNotesIsFoundForFinishing() throws {
        let store = MeetingStore(root: root)
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: Date())
        let unfinished = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: unfinished)

        var done = record
        done.endedAt = Date()
        let finished = try store.makeFolder(for: done)
        try store.saveTranscript(done, in: finished)
        try store.saveNotes("# Notes", in: finished)

        XCTAssertEqual(store.unfinishedFolders().map(\.lastPathComponent), [unfinished.lastPathComponent])
    }

    func testACallTooShortToKeepIsListedNowhere() throws {
        let store = MeetingStore(root: root)
        let start = Date(timeIntervalSince1970: 1_791_468_600)
        let kept = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                 endedAt: start.addingTimeInterval(30))
        let keptFolder = try store.makeFolder(for: kept)
        try store.saveTranscript(kept, in: keptFolder)

        var dropped = MeetingRecord(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp",
                                    startedAt: start.addingTimeInterval(60))
        dropped.add(MeetingSegment(speaker: .them, start: 1, end: 4, text: "A voice message"))
        dropped.endedAt = start.addingTimeInterval(80)
        dropped.droppedAt = dropped.endedAt
        let droppedFolder = try store.makeFolder(for: dropped)
        try store.saveTranscript(dropped, in: droppedFolder)

        XCTAssertEqual(store.calls().map(\.folder.lastPathComponent), [keptFolder.lastPathComponent])
        XCTAssertNil(store.keptRecord(in: droppedFolder))
        XCTAssertNil(store.record(in: droppedFolder.lastPathComponent), "the call search reads it too")
        XCTAssertEqual(store.loadRecord(in: droppedFolder)?.droppedAt, dropped.droppedAt,
                       "still on disk, so a call that comes back can carry on into it")
    }

    func testRemoveTakesAWholeCallFolder() throws {
        let store = MeetingStore(root: root)
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: Date())
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)

        try store.remove(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.calls().isEmpty)
    }

    func testRemoveRefusesAnythingButAFolderRightInsideTheRoot() throws {
        let store = MeetingStore(root: root)
        let record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: Date())
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        let inside = folder.appendingPathComponent(MeetingFiles.recordName)

        XCTAssertThrowsError(try store.remove(root))
        XCTAssertThrowsError(try store.remove(inside))
        XCTAssertThrowsError(try store.remove(root.appendingPathComponent("..", isDirectory: true)))
        XCTAssertThrowsError(try store.remove(folder.appendingPathComponent("../..", isDirectory: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testAnOldRecordWithoutTheDropIsKept() throws {
        let json = #"""
        {"bundleID":"a","appName":"Zoom","startedAt":"2026-10-08T12:52:00Z","endedAt":"2026-10-08T12:53:00Z"}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.droppedAt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertFalse(String(decoding: try encoder.encode(record), as: UTF8.self).contains("droppedAt"),
                       "a kept call's file does not mention it")
    }
}

/// The owner's call, 2026-10-08: a voice message in a chat app looks like a
/// call to the detector, so notes that end on their own before five minutes
/// leave nothing behind.
final class MeetingNotesShortCallTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private func call(_ id: String = "net.whatsapp.WhatsApp") -> OngoingCall {
        OngoingCall(bundleID: id, appName: "WhatsApp", startedAt: now)
    }

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event,
                      autoStart: Bool = false) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: true, autoStart: autoStart)
    }

    /// Notes on `call()` since `now`, with the real shortest kept.
    private func recording() -> MeetingNotesFlow {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .callStarted(call(), at: now))
        _ = send(&flow, .accept(at: now))
        return flow
    }

    /// The call lets go of the microphone at `seconds` and the notes stop.
    private func endOnItsOwn(_ flow: inout MeetingNotesFlow, at seconds: TimeInterval) -> [MeetingNotesFlow.Effect] {
        _ = send(&flow, .callEnded(at: at(seconds)))
        return send(&flow, .tick(.init(now: at(seconds + 60), callOnMic: false)))
    }

    func testFiveMinutes() {
        XCTAssertEqual(MeetingNotesFlow.shortestKept, 5 * 60)
    }

    func testAVoiceMessageLeavesNothingBehind() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 40), [.dropNotes])
        XCTAssertEqual(flow.phase, .idle, "no \"Writing notes…\", no \"Not enough was said\"")
        XCTAssertEqual(flow.pillMark(now: at(100), muted: false), .none)
    }

    func testACallJustShortOfFiveMinutesIsNotKept() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 5 * 60 - 1), [.dropNotes])
    }

    func testACallOfFiveMinutesIsWrittenUp() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 5 * 60), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
    }

    func testNotesStoppedByHandAreWrittenHoweverShort() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .stop), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(call()))
    }

    func testTheMacSleepingOnAShortCallKeepsNothing() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .sleep(at: at(90))), [.dropNotes])
        XCTAssertEqual(flow.phase, .idle)
    }

    func testAnotherAppsCallDropsAShortOneAndIsAskedAboutAsUsual() {
        var flow = recording()
        XCTAssertEqual(send(&flow, .callStarted(call("us.zoom.xos"), at: at(30))), [.dropNotes])
        XCTAssertEqual(flow.phase, .offering(call("us.zoom.xos")))
    }

    func testAShortCallThatComesStraightBackCarriesOnFromItsFirstStart() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 200), [.dropNotes])
        XCTAssertEqual(send(&flow, .callStarted(call(), at: at(300))),
                       [.startNotes(call(), continuing: true)])
        XCTAssertEqual(flow.firstStarted, now, "counted from the first start, not the return")

        // 200 s before the drop and 150 s after it: kept as one call.
        XCTAssertEqual(endOnItsOwn(&flow, at: 450), [.finishNotes])
    }

    func testTwoShortStretchesStillShortTogetherKeepNothing() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 60), [.dropNotes])
        _ = send(&flow, .callStarted(call(), at: at(150)))
        XCTAssertEqual(endOnItsOwn(&flow, at: 200), [.dropNotes])
    }

    func testAShortCallBackTooLateIsANewCall() {
        var flow = recording()
        XCTAssertEqual(endOnItsOwn(&flow, at: 40), [.dropNotes])
        let late = at(40 + MeetingNotesFlow.sameMeetingWindow + 1)
        XCTAssertEqual(send(&flow, .callStarted(call(), at: late)), [])
        XCTAssertEqual(flow.phase, .offering(call()))
    }
}
