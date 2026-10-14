import XCTest
@testable import AirlockCore

/// Notes taken by hand of a meeting in the room: no call, the Mac's own
/// microphone, everybody on one side.
final class InPersonNotesFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private var room: OngoingCall { .inPerson(at: now) }
    private func zoom(at date: Date) -> OngoingCall {
        OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: date)
    }

    private func send(_ flow: inout MeetingNotesFlow, _ event: MeetingNotesFlow.Event,
                      enabled: Bool = true) -> [MeetingNotesFlow.Effect] {
        flow.apply(event, enabled: enabled, autoStart: false)
    }

    /// Room notes under way since `now`, keeping only notes of five minutes
    /// or more, as the app does.
    private func taking() -> MeetingNotesFlow {
        var flow = MeetingNotesFlow()
        _ = send(&flow, .takeNotesInPerson(at: now))
        return flow
    }

    func testTheButtonStartsNotesWithNoCall() {
        var flow = MeetingNotesFlow()
        XCTAssertEqual(flow.handButton, .takeNotes)
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: now)), [.startNotes(room, continuing: false)])
        XCTAssertEqual(flow.phase, .recording(room, since: now))
        XCTAssertEqual(flow.handButton, .stop)
        XCTAssertEqual(flow.pillMark(now: now, muted: false), .recording)
    }

    func testNothingStartsWithCallNotesOff() {
        var flow = MeetingNotesFlow()
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: now), enabled: false), [])
        XCTAssertEqual(flow.phase, .idle)
    }

    func testTheButtonStartsAgainFromNotesReadyOrFailed() {
        var ready = MeetingNotesFlow(previewing: .ready(folder: "f", call: zoom(at: now)))
        XCTAssertEqual(ready.handButton, .takeNotes)
        XCTAssertEqual(send(&ready, .takeNotesInPerson(at: at(5))),
                       [.startNotes(.inPerson(at: at(5)), continuing: false)])

        var failed = MeetingNotesFlow(previewing: .failed("no microphone"))
        XCTAssertEqual(send(&failed, .takeNotesInPerson(at: at(5))),
                       [.startNotes(.inPerson(at: at(5)), continuing: false)])
    }

    /// On a call, the same button takes notes of the call, and while notes
    /// are being written it is not there at all.
    func testOnACallOrWhileWritingTheRoomIsNotStarted() {
        var offered = MeetingNotesFlow()
        _ = send(&offered, .callStarted(zoom(at: now), at: now))
        XCTAssertEqual(offered.handButton, .takeNotesOfCall)
        XCTAssertEqual(send(&offered, .takeNotesInPerson(at: now)), [])
        XCTAssertEqual(offered.phase, .offering(zoom(at: now)))

        var writing = MeetingNotesFlow(previewing: .writing(room))
        XCTAssertEqual(writing.handButton, .busy)
        XCTAssertEqual(send(&writing, .takeNotesInPerson(at: now)), [])

        var flow = taking()
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: at(30))), [])
        XCTAssertEqual(flow.phase, .recording(room, since: now))
    }

    /// A call starting or ending on the Mac (a FaceTime ringing through, a
    /// meeting app opened by mistake) is not the meeting in the room.
    func testACallStartingOrEndingDoesNotTouchTheRoomNotes() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .callStarted(zoom(at: at(60)), at: at(60))), [])
        XCTAssertEqual(send(&flow, .callEnded(at: at(90))), [])
        XCTAssertEqual(flow.phase, .recording(room, since: now))
        XCTAssertFalse(flow.isWaitingForCallBack)
    }

    func testStopWritesTheNotesHoweverShort() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .stop), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(room))
        XCTAssertFalse(flow.endedBySleep)
    }

    /// A minute of notes, then the lid: kept, and said to have stopped
    /// because the Mac slept. A call this short would leave nothing.
    func testSleepKeepsShortRoomNotesAndSaysWhy() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .sleep(at: at(60))), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(room))
        XCTAssertTrue(flow.endedBySleep)
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(flow.phase, .ready(folder: "f", call: room))
        XCTAssertTrue(flow.endedBySleep, "still said once the notes are ready")

        var call = MeetingNotesFlow()
        _ = send(&call, .callStarted(zoom(at: now), at: now))
        _ = send(&call, .accept(at: now))
        XCTAssertEqual(send(&call, .sleep(at: at(60))), [.dropNotes])
    }

    /// Waking up with the lid open again does not carry the room notes on:
    /// there is no call to find again, so the next ones are new.
    func testAfterTheSleepTheNextNotesAreNew() {
        var flow = taking()
        _ = send(&flow, .sleep(at: at(60)))
        _ = send(&flow, .saved(folder: "f"))
        XCTAssertEqual(send(&flow, .takeNotesInPerson(at: at(600))),
                       [.startNotes(.inPerson(at: at(600)), continuing: false)])
        XCTAssertFalse(flow.endedBySleep)

        var dismissed = taking()
        _ = send(&dismissed, .sleep(at: at(60)))
        _ = send(&dismissed, .saved(folder: "f"))
        _ = send(&dismissed, .dismiss)
        XCTAssertEqual(dismissed.phase, .idle)
        XCTAssertFalse(dismissed.endedBySleep)
    }

    /// Fifteen quiet minutes still stop the notes (somebody forgot them),
    /// and what was said before is kept.
    func testFifteenQuietMinutesStopAndKeepTheNotes() {
        var flow = taking()
        XCTAssertEqual(send(&flow, .tick(.init(now: at(120), lastSpeech: at(100)))), [])
        XCTAssertEqual(send(&flow, .tick(.init(now: at(1_000), lastSpeech: at(100)))), [.finishNotes])
        XCTAssertEqual(flow.phase, .writing(room))
        XCTAssertFalse(flow.endedBySleep)
    }
}

final class InPersonRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func roomRecord(event: MeetingEvent? = nil, _ segments: [MeetingSegment] = []) -> MeetingRecord {
        MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: start,
                      segments: segments, event: event)
    }

    func testTheRoomIsACallOfItsOwn() {
        let room = OngoingCall.inPerson(at: start)
        XCTAssertTrue(room.isInPerson)
        XCTAssertEqual(room.startedAt, start)
        XCTAssertFalse(OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start).isInPerson)
        XCTAssertTrue(roomRecord().isInPerson)
    }

    /// Nobody is "You" in the room: a numbered voice is "Person 2", any
    /// other line is "Someone", and one person on the invite is not taken
    /// to be the one talking.
    func testLinesAreNumberedVoicesOrSomeoneNeverYou() {
        let record = roomRecord(event: MeetingEvent(title: "", start: start, attendees: ["Ana"]))
        XCTAssertNil(record.otherName)
        XCTAssertEqual(record.label(for: MeetingSegment(speaker: .them, start: 0, end: 1, text: "Hi", person: 2)),
                       "Person 2")
        XCTAssertEqual(record.label(for: MeetingSegment(speaker: .them, start: 0, end: 1, text: "Hi")), "Someone")
        XCTAssertEqual(record.label(for: .me), "Someone")
        XCTAssertEqual(record.label(for: .them), "Someone")
    }

    func testTheTitleSaysMeetingNotCall() {
        XCTAssertEqual(MeetingFiles.title(of: roomRecord()), "Meeting in person")
        XCTAssertEqual(MeetingFiles.title(of: roomRecord(event: MeetingEvent(title: "", start: start,
                                                                             attendees: ["Ana"]))),
                       "Meeting with Ana")
        XCTAssertEqual(MeetingFiles.title(of: roomRecord(event: MeetingEvent(title: "Shop rota", start: start))),
                       "Shop rota")
        XCTAssertTrue(MeetingFiles.folderName(for: roomRecord()).hasSuffix("– In person"))
    }

    func testTheTranscriptNeverSaysYou() {
        let record = roomRecord([
            MeetingSegment(speaker: .them, start: 1, end: 3, text: "Shall we start?"),
            MeetingSegment(speaker: .them, start: 20, end: 24, text: "Yes, the rota first.", person: 1),
        ])
        let page = MeetingFiles.transcript(of: record)
        XCTAssertTrue(page.contains("**Someone** · 0:01"), page)
        XCTAssertTrue(page.contains("**Person 1** · 0:20"), page)
        XCTAssertFalse(page.contains("**You**"), page)
    }
}

final class InPersonPeopleTests: XCTestCase {
    func testTheModelIsToldItWasTheRoomAndNobodyIsYou() {
        let voices = MeetingPeople(others: [], voices: 3, inPerson: true)
        XCTAssertEqual(voices.names(), ["Person 1", "Person 2", "Person 3"])
        XCTAssertTrue(voices.promptLine.contains("meeting in the room"), voices.promptLine)
        XCTAssertTrue(voices.promptLine.contains("Person 1 to Person 3"), voices.promptLine)
        XCTAssertTrue(voices.promptLine.contains("Nobody here is \"You\""), voices.promptLine)

        let one = MeetingPeople(others: ["Ana García", "Marc"], voices: 0, inPerson: true)
        XCTAssertTrue(one.promptLine.contains("Every line is Someone"), one.promptLine)
        XCTAssertTrue(one.promptLine.hasSuffix(" Invited: Ana García, Marc."), one.promptLine)
        XCTAssertEqual(one.names(), ["Ana García", "Marc"])
    }

    /// A to-do the model gives to "you" has no owner in the room; a name
    /// or a voice still does.
    func testYouIsNobodysName() {
        let room = MeetingPeople(others: ["Ana García"], voices: 2, inPerson: true)
        XCTAssertNil(room.owner("You"))
        XCTAssertNil(room.owner("tú"))
        XCTAssertEqual(room.owner("Ana"), "Ana García")
        XCTAssertEqual(room.owner("Person 2"), "Person 2")

        let call = MeetingPeople(others: ["Ana García"], voices: 2)
        XCTAssertEqual(call.owner("You"), "You")
        XCTAssertEqual(call.names(), ["You", "Ana García", "Person 1", "Person 2"])
    }

    func testPeopleFromARoomRecord() {
        let record = MeetingRecord(
            bundleID: OngoingCall.inPersonBundleID, appName: "In person", startedAt: Date(),
            segments: [
                MeetingSegment(speaker: .them, start: 1, end: 2, text: "One", person: 1),
                MeetingSegment(speaker: .them, start: 3, end: 4, text: "Two", person: 2),
            ])
        let people = MeetingPeople(record: record)
        XCTAssertTrue(people.inPerson)
        XCTAssertEqual(people.voices, 2)
    }
}

final class InPersonLooksTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_468_600)

    /// The microphone is the only side in the room: said missing once
    /// nothing has come from it for ten seconds, never the call's sound.
    func testTheRoomMicrophoneIsMissingAfterTenSilentSeconds() {
        var health = CallChannelHealth()
        let mic = CallChannelHealth.Side(since: now, lastInput: now.addingTimeInterval(2))
        health.update(room: mic, now: now.addingTimeInterval(11.9))
        XCTAssertFalse(health.yoursMissing)
        health.update(room: mic, now: now.addingTimeInterval(12))
        XCTAssertTrue(health.yoursMissing)
        XCTAssertFalse(health.theirsMissing)
        XCTAssertFalse(health.theirsNotAllowed)

        health.update(room: CallChannelHealth.Side(since: now), now: now.addingTimeInterval(9))
        XCTAssertFalse(health.yoursMissing, "nothing yet, but not for ten seconds")
        health.update(room: CallChannelHealth.Side(), now: now.addingTimeInterval(60))
        XCTAssertFalse(health.yoursMissing, "the microphone hasn't been asked for yet")
    }

    func testTheButtonsWords() {
        XCTAssertEqual(CallsCard.handLabel(.takeNotes), "Take notes")
        XCTAssertEqual(CallsCard.handLabel(.takeNotesOfCall), "Take notes")
        XCTAssertEqual(CallsCard.handLabel(.stop), "Stop notes")
        XCTAssertNil(CallsCard.handLabel(.busy))
        XCTAssertTrue(CallsCard.handHelp(.takeNotes).contains("in the room"))
    }

    func testThePillSaysNotesOfAMeetingInPerson() {
        XCTAssertEqual(CompactSlot.call(.inPerson(at: now)).accessibilityLabel,
                       "Taking notes of a meeting in person")
        XCTAssertEqual(CompactSlot.call(OngoingCall(bundleID: "us.zoom.xos", appName: "Zoom",
                                                    startedAt: now)).accessibilityLabel,
                       "On a call in Zoom")
    }
}
