import AirlockCore
import XCTest
@testable import AirlockApp

/// The panel's line once a call is over, on a previewing model (no
/// microphone, no timers, nothing written): which call it names, and
/// whether it says the notes are ready or that too little was said.
@MainActor
final class CallNotesLineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private var faceTime: OngoingCall {
        OngoingCall(bundleID: "com.apple.FaceTime", appName: "FaceTime", startedAt: start)
    }

    private func record(event: MeetingEvent?, words: Int = 0) -> MeetingRecord {
        let text = (0..<words).map { "word\($0)" }.joined(separator: " ")
        return MeetingRecord(bundleID: "com.apple.FaceTime", appName: "FaceTime", startedAt: start,
                             endedAt: start.addingTimeInterval(600),
                             segments: words == 0 ? [] : [MeetingSegment(speaker: .them, start: 0, end: 9, text: text)],
                             event: event)
    }

    private func model(_ phase: MeetingNotesFlow.Phase, record: MeetingRecord? = nil,
                       notes: MeetingNotes? = nil, event: MeetingEvent? = nil) -> MeetingNotesModel {
        MeetingNotesModel(previewing: MeetingNotesFlow(previewing: phase), record: record, notes: notes, event: event)
    }

    // MARK: - The call's name

    /// "Writing your notes…" and "Notes ready" name the call as the list of
    /// past calls will: never a bare person's name.
    func testTheLineNamesTheCallAsTheListDoes() {
        let events: [MeetingEvent?] = [
            MeetingEvent(title: "Launch stand-up", start: start, attendees: ["Ana", "Bo"]),
            MeetingEvent(title: "", start: start, attendees: ["Ana"]),
            MeetingEvent(title: "", start: start, attendees: ["Ana", "Bo"]),
            nil,
        ]
        for event in events {
            let saved = record(event: event)
            let listed = MeetingFiles.title(of: saved)
            let writing = model(.writing(faceTime), record: saved)
            XCTAssertEqual(writing.listedTitle(faceTime), listed)
            let ready = model(.ready(folder: "/var/empty/call", call: faceTime), record: saved)
            XCTAssertEqual(ready.listedTitle(faceTime), listed)
        }
    }

    /// While the notes are written the record may not be to hand yet; the
    /// event the call was matched to names it the same way.
    func testAOneToOneCallIsACallWithThatPerson() {
        let withAna = MeetingEvent(title: "", start: start, attendees: ["Ana"])
        let writing = model(.writing(faceTime), event: withAna)
        XCTAssertEqual(writing.listedTitle(faceTime), "Call with Ana")
        XCTAssertEqual(model(.writing(faceTime)).listedTitle(faceTime), "Call in FaceTime")
    }

    // MARK: - Ready, or too little said

    func testACallWithTooFewWordsSaysSo() {
        let ready = MeetingNotesFlow.Phase.ready(folder: "/var/empty/call", call: faceTime)
        XCTAssertEqual(model(ready, record: record(event: nil)).readyOutcome, .tooLittleSaid)
        XCTAssertEqual(model(ready, record: record(event: nil, words: MeetingNotes.minimumWords - 1)).readyOutcome,
                       .tooLittleSaid)
        XCTAssertEqual(model(ready, record: record(event: nil, words: MeetingNotes.minimumWords),
                             notes: MeetingNotes(summary: "We agreed on the launch.")).readyOutcome, .notes)
    }
}
