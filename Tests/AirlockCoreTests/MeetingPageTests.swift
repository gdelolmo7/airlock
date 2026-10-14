import XCTest
@testable import AirlockCore

final class MeetingPageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)
    private let utc = TimeZone(identifier: "UTC")!

    func testTheNotesPageReadsBackAsItsParts() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600),
                                   segments: [MeetingSegment(speaker: .me, start: 0, end: 1, text: "Hello")])
        record.jot("Ask — about Q3", at: 75)
        let notes = MeetingNotes(summary: "We agreed on Friday.",
                                 todos: [.init(text: "Send the deck", owner: "Ana García", sources: [1], at: 3_729),
                                         .init(text: "Book a room", sources: [1], at: 61)],
                                 keyPoints: [.init(text: "Budget is fine", sources: [1], at: 0)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)
        let body = MeetingPage.body(of: page, header: MeetingFiles.header(of: record, timeZone: utc))
        XCTAssertEqual(Array(body.prefix(9)), [
            .heading("Summary", level: 2),
            .paragraph("We agreed on Friday."),
            .heading("Your notes", level: 2),
            .item("Ask — about Q3", checked: nil, owner: nil, at: 75),
            .heading("To-dos", level: 2),
            .item("Send the deck", checked: false, owner: "Ana García", at: 3_729),
            .item("Book a room", checked: false, owner: nil, at: 61),
            .heading("Key points", level: 2),
            .item("Budget is fine", checked: nil, owner: nil, at: 0),
        ])
        XCTAssertEqual(body[9], .rule)
        if case .paragraph(let closing) = body.last {
            XCTAssertTrue(closing.contains("No audio was kept"))
        } else {
            XCTFail("the closing line is a paragraph")
        }
    }

    /// The line about minutes with no notes reads back as itself, where it
    /// was written, and is never taken for the person's own words.
    func testMinutesWithNoNotesReadBackFromThePage() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(2_700),
                                   segments: [MeetingSegment(speaker: .me, start: 0, end: 1, text: "Hello")])
        record.jot("Ask about Q3", at: 75)
        let notes = MeetingNotes(summary: "We agreed on Friday.",
                                 todos: [.init(text: "Send the deck", sources: [1], at: 61)],
                                 unwritten: [.init(start: 1_930, end: 2_645), .init(start: 3_600, end: 3_729)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)
        let placed = MeetingPage.placed(MeetingPage.body(of: page, header: MeetingFiles.header(of: record, timeZone: utc)))
        XCTAssertEqual(Array(placed.map(\.block).prefix(6)), [
            .heading("Summary", level: 2),
            .paragraph("We agreed on Friday."),
            .unwritten(from: 1_930, to: 2_645),
            .unwritten(from: 3_600, to: 3_729),
            .heading("Your notes", level: 2),
            .item("Ask about Q3", checked: nil, owner: nil, at: 75),
        ])
        XCTAssertEqual(placed[2].section, "Summary")
        XCTAssertFalse(placed[2].isYours)
    }

    func testOnlyTheLineAsWrittenIsReadAsMinutesWithNoNotes() {
        XCTAssertEqual(MeetingPage.blocks(of: "Couldn't write notes for 4:05–1:02:09. The transcript has it all."),
                       [.unwritten(from: 245, to: 3_729)], "without its italics too")
        for edited in ["_Couldn't write notes for 4:05. The transcript has it all._",
                       "_Couldn't write notes for 9:00–4:05. The transcript has it all._",
                       "_Couldn't write notes for 4:05–9:00. Ask Ana._",
                       "Couldn't write notes for 4:05–9:00. The transcript has it all. Mostly."] {
            XCTAssertEqual(MeetingPage.blocks(of: edited), [.paragraph(edited)], edited)
        }
    }

    /// Pages written before lines carried a time read exactly as before.
    func testAnOlderPageReadsAsBefore() {
        let page = """
            # Notes: call in Zoom

            ## Action items

            - [ ] Ana: pricing page copy — by Thursday
            - [ ] Tell the others · soon
            - Budget is fine
            """
        XCTAssertEqual(MeetingPage.blocks(of: page), [
            .heading("Notes: call in Zoom", level: 1),
            .heading("Action items", level: 2),
            .item("Ana: pricing page copy — by Thursday", checked: false),
            .item("Tell the others · soon", checked: false),
            .item("Budget is fine", checked: nil),
        ])
    }

    func testOnlyAClockCountsAsATime() {
        XCTAssertEqual(MeetingPage.seconds("4:05"), 245)
        XCTAssertEqual(MeetingPage.seconds("112:00"), 6_720)
        XCTAssertEqual(MeetingPage.seconds("1:02:09"), 3_729)
        for wrong in ["4:5", "4:65", "a:05", "4:05pm", "1:2:3", "", "1234:00", ":05", "4:٠٥"] {
            XCTAssertNil(MeetingPage.seconds(wrong), wrong)
        }
    }

    func testAnOwnerIsOnlyReadOnAToDo() {
        XCTAssertEqual(MeetingPage.blocks(of: "- Plan B — the cheap one · 3:00"),
                       [.item("Plan B — the cheap one", checked: nil, owner: nil, at: 180)])
        XCTAssertEqual(MeetingPage.blocks(of: "- [x] Plan B — Luis · 3:00"),
                       [.item("Plan B", checked: true, owner: "Luis", at: 180)])
    }

    func testAnEditedPageKeepsWhatItDoesNotUnderstand() {
        let page = "# My call\n\nSome words\nwrapped here.\n\n> a quote\n- [x] Done thing\n"
        XCTAssertEqual(MeetingPage.body(of: page, header: "not this"), [
            .paragraph("Some words wrapped here."),
            .paragraph("> a quote"),
            .item("Done thing", checked: true),
        ])
    }

    /// The window draws the person's own lines apart from Airlock's, so it
    /// has to know which heading each line sits under.
    func testEachLineKnowsTheHeadingItSitsUnder() {
        var record = MeetingRecord(bundleID: "a", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(600),
                                   segments: [MeetingSegment(speaker: .me, start: 0, end: 1, text: "Hello")])
        record.jot("Ask about Q3", at: 75)
        let notes = MeetingNotes(summary: "We agreed on Friday.",
                                 todos: [.init(text: "Send the deck", owner: "Ana", sources: [1], at: 3)])
        let page = MeetingFiles.notesPage(for: record, notes: notes, timeZone: utc)
        let placed = MeetingPage.placed(MeetingPage.body(of: page, header: MeetingFiles.header(of: record, timeZone: utc)))

        XCTAssertEqual(placed.map(\.isYours), [false, false, false, true, false, false, false, false])
        XCTAssertEqual(placed[3].block, .item("Ask about Q3", checked: nil, owner: nil, at: 75))
        XCTAssertEqual(placed[3].section, "Your notes")
        XCTAssertEqual(placed[5].section, "To-dos")
        XCTAssertEqual(placed.map(\.closing), [false, false, false, false, false, false, true, true])
    }

    func testLinesAboveAnyHeadingBelongToNoSection() {
        let placed = MeetingPage.placed(MeetingPage.blocks(of: "Loose words\n\n## Your notes\n\n- Mine · 0:05\n\n---\n\nAfter"))
        XCTAssertEqual(placed.map(\.section), [nil, "Your notes", "Your notes", "Your notes", "Your notes"])
        // Neither the heading nor the closing line is the person's.
        XCTAssertEqual(placed.map(\.isYours), [false, false, true, false, false])
    }

    func testCallsAreListedNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-calls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        for (offset, app) in [(0.0, "Zoom"), (3_600.0, "Teams")] {
            let record = MeetingRecord(bundleID: app, appName: app, startedAt: start.addingTimeInterval(offset))
            try store.saveTranscript(record, in: store.makeFolder(for: record))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not a call"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(store.calls().map(\.record.appName), ["Teams", "Zoom"])
    }

    // MARK: - Cards

    /// What sits above the first heading, then a card per heading with what
    /// is under it, and the closing line apart, without its rule.
    func testThePageComesApartIntoCardsAndAClosingLine() {
        let page = """
        # Notes: call in Zoom

        Header line

        _Written from the transcript only_

        ## Summary

        We agreed.

        ## To-dos

        - [ ] Send it — Ana · 0:23
        - [x] Book it

        ## Empty

        ---

        _Written on this Mac by Airlock._
        """
        let (sections, closing) = MeetingPage.sections(MeetingPage.placed(MeetingPage.body(of: page, header: "Header line")))
        XCTAssertEqual(sections.map(\.heading), [nil, "Summary", "To-dos", "Empty"])
        XCTAssertEqual(sections.map(\.lines.count), [1, 1, 2, 0])
        XCTAssertEqual(sections[2].lines.first?.block, .item("Send it", checked: false, owner: "Ana", at: 23))
        XCTAssertEqual(closing.map(\.block), [.paragraph("_Written on this Mac by Airlock._")])
    }

    func testAPageWithNoHeadingIsOneSectionWithNone() {
        let (sections, closing) = MeetingPage.sections(MeetingPage.placed([.paragraph("Just this.")]))
        XCTAssertEqual(sections, [MeetingPage.Section(heading: nil, lines: [
            MeetingPage.Placed(block: .paragraph("Just this."), section: nil, closing: false)])])
        XCTAssertEqual(closing, [])
        XCTAssertEqual(MeetingPage.sections([]).sections, [])
    }
}
