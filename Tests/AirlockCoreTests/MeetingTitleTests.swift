import AirlockTestSupport
import XCTest
@testable import AirlockCore

/// A meeting nothing else names is named by its notes: "Kitchen tiles and
/// delivery dates" rather than "Meeting in person".
final class MeetingTitleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func record(event: MeetingEvent? = nil, recording: MeetingRecording? = nil,
                        inPerson: Bool = false, topic: String? = nil) -> MeetingRecord {
        MeetingRecord(bundleID: inPerson ? OngoingCall.inPersonBundleID : "us.zoom.xos",
                      appName: inPerson ? "In person" : "Zoom", startedAt: start,
                      endedAt: start.addingTimeInterval(600),
                      segments: [MeetingSegment(speaker: .them, start: 5, end: 12,
                                                text: "The tiles arrive on Monday, not Friday.")],
                      event: event, recording: recording, topic: topic)
    }

    // MARK: - Cleaning what the model wrote

    func testATitleIsKeptAsWrittenWhenItIsAlreadyAName() {
        XCTAssertEqual(MeetingNotes.title("Kitchen tiles and delivery dates"), "Kitchen tiles and delivery dates")
    }

    func testLabelsQuotesAndAFullStopAreTakenOff() {
        XCTAssertEqual(MeetingNotes.title("Title: Kitchen tiles."), "Kitchen tiles")
        XCTAssertEqual(MeetingNotes.title("Título: Azulejos de la cocina"), "Azulejos de la cocina")
        XCTAssertEqual(MeetingNotes.title("\"Kitchen tiles\""), "Kitchen tiles")
        XCTAssertEqual(MeetingNotes.title("“Kitchen tiles”."), "Kitchen tiles")
        XCTAssertEqual(MeetingNotes.title("**Kitchen tiles**"), "Kitchen tiles")
        XCTAssertEqual(MeetingNotes.title("«Rajoles de la cuina»"), "Rajoles de la cuina")
    }

    func testAColonThatIsPartOfTheNameStays() {
        XCTAssertEqual(MeetingNotes.title("Q4 budget: final review"), "Q4 budget: final review")
    }

    func testOnlyTheFirstLineIsTheTitle() {
        XCTAssertEqual(MeetingNotes.title("Kitchen tiles\nThe meeting was about tiles."), "Kitchen tiles")
        XCTAssertEqual(MeetingNotes.title("  Kitchen   tiles  "), "Kitchen tiles")
    }

    func testALongTitleIsCutBetweenWords() throws {
        let long = "Kitchen tiles, delivery dates, the plumber's quote, the electrician and the paint colours"
        let title = try XCTUnwrap(MeetingNotes.title(long))
        XCTAssertLessThanOrEqual(title.count, MeetingNotes.titleLimit)
        XCTAssertTrue(long.hasPrefix(title))
        XCTAssertEqual(title, "Kitchen tiles, delivery dates, the plumber's quote, the")
        let word = String(repeating: "a", count: 80)
        XCTAssertEqual(MeetingNotes.title(word)?.count, MeetingNotes.titleLimit, "one word is cut where it must")
    }

    func testNothingOrAPlaceholderIsNoTitle() {
        for text in [nil, "", "  ", "\n", "\"\"", "Title:", "Meeting", "Call.", "Untitled", "Reunión"] {
            XCTAssertNil(MeetingNotes.title(text), String(describing: text))
        }
    }

    func testNotesCleanTheirTitleHoweverItIsSet() {
        var notes = MeetingNotes(summary: "Tiles.", title: "Title: \"Kitchen tiles.\"")
        XCTAssertEqual(notes.title, "Kitchen tiles")
        notes.title = "  “Delivery dates”  "
        XCTAssertEqual(notes.title, "Delivery dates")
        notes.title = "Untitled"
        XCTAssertNil(notes.title)
    }

    // MARK: - Which name wins

    func testTheCalendarAndARecordingStillWinOverTheNotes() {
        let named = record(event: MeetingEvent(title: "Weekly sync", start: start), topic: "Kitchen tiles")
        XCTAssertEqual(MeetingFiles.title(of: named), "Weekly sync")
        let recorded = record(recording: MeetingRecording(fileName: "Site visit.m4a", seconds: 600),
                              topic: "Kitchen tiles")
        XCTAssertEqual(MeetingFiles.title(of: recorded), "Site visit")
    }

    func testTheNotesNameWinsOverWhoAndWhere() {
        let oneToOne = MeetingEvent(title: "", start: start, attendees: ["Ana García"])
        XCTAssertEqual(MeetingFiles.title(of: record(event: oneToOne)), "Call with Ana García")
        XCTAssertEqual(MeetingFiles.title(of: record(event: oneToOne, topic: "Kitchen tiles")), "Kitchen tiles")
        XCTAssertEqual(MeetingFiles.title(of: record(inPerson: true)), "Meeting in person")
        XCTAssertEqual(MeetingFiles.title(of: record(inPerson: true, topic: "Kitchen tiles")), "Kitchen tiles")
        XCTAssertEqual(MeetingFiles.title(of: record(topic: "Kitchen tiles")), "Kitchen tiles")
        XCTAssertEqual(MeetingFiles.title(event: nil, callName: "Zoom", topic: "Kitchen tiles"), "Kitchen tiles")
    }

    func testTheNotesNameIsANameAndKeepsItsCapitals() {
        XCTAssertFalse(MeetingFiles.titleIsAName(record(inPerson: true)))
        XCTAssertTrue(MeetingFiles.titleIsAName(record(inPerson: true, topic: "Kitchen tiles")))

        let page = MeetingFiles.notesPage(for: record(inPerson: true),
                                          notes: MeetingNotes(summary: "Tiles.", title: "Kitchen Tiles"),
                                          timeZone: utc)
        XCTAssertTrue(page.hasPrefix("# Notes: Kitchen Tiles\n"), page)
        let untitled = MeetingFiles.notesPage(for: record(inPerson: true),
                                              notes: MeetingNotes(summary: "Tiles."), timeZone: utc)
        XCTAssertTrue(untitled.hasPrefix("# Notes: meeting in person\n"), untitled)
    }

    func testNotesWithoutATitleKeepTheNameTheMeetingHas() {
        let page = MeetingFiles.notesPage(for: record(topic: "Kitchen tiles"),
                                          notes: MeetingNotes(summary: "Tiles."), timeZone: utc)
        XCTAssertTrue(page.hasPrefix("# Notes: Kitchen tiles\n"), page)
    }

    func testTheFolderIsNeverNamedByTheNotes() {
        XCTAssertEqual(MeetingFiles.folderName(for: record(topic: "Kitchen tiles"), timeZone: utc),
                       MeetingFiles.folderName(for: record(), timeZone: utc))
    }

    // MARK: - On disk

    func testAnOlderRecordHasNoTopicAndANewOneKeepsIt() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let old = #"{"bundleID":"a","appName":"Zoom","startedAt":"2026-10-08T12:52:00Z"}"#
        XCTAssertNil(try decoder.decode(MeetingRecord.self, from: Data(old.utf8)).topic)
        XCTAssertFalse(String(decoding: try encoder.encode(record()), as: UTF8.self).contains("topic"),
                       "meeting.json is what it always was until notes name it")

        let named = record(topic: "Kitchen tiles")
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: encoder.encode(named)), named)
        XCTAssertEqual(record(topic: "Title: \"Kitchen tiles.\"").topic, "Kitchen tiles")
    }

    func testTheStoreSavesTheTitleInTheRecordAndTheTranscript() throws {
        let scratch = TestScratch("title")
        let store = MeetingStore(root: scratch.root)
        let meeting = record(inPerson: true)
        let folder = try store.makeFolder(for: meeting, timeZone: utc)
        try store.saveTranscript(meeting, in: folder, timeZone: utc)
        let transcript = { try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcriptName),
                                      encoding: .utf8) }
        XCTAssertTrue(try transcript().hasPrefix("# Meeting in person\n"))

        try store.saveTopic("Kitchen tiles.", in: folder, timeZone: utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.topic, "Kitchen tiles")
        XCTAssertTrue(try transcript().hasPrefix("# Kitchen tiles\n"))

        try store.saveTopic(nil, in: folder, timeZone: utc)
        try store.saveTopic("Untitled", in: folder, timeZone: utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.topic, "Kitchen tiles", "notes that name nothing take nothing away")

        try store.saveTopic("Delivery dates", in: folder, timeZone: utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.topic, "Delivery dates", "notes written again rename it")
    }

    func testNamingAVoiceKeepsTheTitle() throws {
        let scratch = TestScratch("title")
        let store = MeetingStore(root: scratch.root)
        let meeting = record(inPerson: true)
        let folder = try store.makeFolder(for: meeting, timeZone: utc)
        try store.saveTranscript(meeting, in: folder, timeZone: utc)
        try store.saveTopic("Kitchen tiles", in: folder, timeZone: utc)

        try store.saveNames(of: meeting, in: folder, timeZone: utc)
        XCTAssertEqual(store.loadRecord(in: folder)?.topic, "Kitchen tiles",
                       "a record read before the notes were written does not take the title away")
    }

    // MARK: - Online

    func testTheOnlineAnswerCarriesTheTitleIntoTheNotes() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(
            #"{"summary": "Tiles.", "title": "Kitchen tiles.", "decisions": [], "todos": [], "questions": [], "keyPoints": []}"#))
        XCTAssertEqual(draft.title, "Kitchen tiles.")
        let notes = CloudNotes.notes(from: draft, record: record()).notes
        XCTAssertEqual(notes.title, "Kitchen tiles")
    }

    func testAnOnlineAnswerWithoutATitleIsStillRead() throws {
        let draft = try XCTUnwrap(CloudNotes.parse(#"{"summary": "Tiles.", "decisions": []}"#))
        XCTAssertEqual(draft.title, "")
        XCTAssertNil(CloudNotes.notes(from: draft, record: record()).notes.title)
    }
}
