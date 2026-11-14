import XCTest
@testable import AirlockCore

/// Changes the person makes to a notes page in the notes window: made to the
/// Markdown itself, keeping what the line carries besides its words, and
/// kept through names given afterwards.
final class MeetingPageEditTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private let page = """
    # Notes: meeting in person

    ## Summary

    Person 2 runs the warehouse.

    ## To-dos

    - [ ] Send the figures — Person 2 · 0:40
    - [x] Book a room · 1:00

    ## Decisions

    - ✓ **Budget:** keep it at ten · 2:10

    ## Open questions

    """

    private func room() -> MeetingRecord {
        var record = MeetingRecord(bundleID: OngoingCall.inPersonBundleID, appName: "In person",
                                   startedAt: start, endedAt: start.addingTimeInterval(900))
        for (index, person) in [1, 2, 3].enumerated() {
            let at = TimeInterval(index * 20)
            record.add(MeetingSegment(speaker: .them, start: at, end: at + 5,
                                      text: "Line \(index).", person: person))
        }
        return record
    }

    private func line(_ text: String, in page: String) -> Range<Int> {
        let index = MeetingPage.lines(of: page).firstIndex { $0.contains(text) }!
        return index..<(index + 1)
    }

    // MARK: - Ticks

    func testATickIsSavedAndTakenBack() {
        let ticked = MeetingPageEdit.toggle(page, lines: line("Send the figures", in: page))
        XCTAssertTrue(ticked.contains("- [x] Send the figures — Person 2 · 0:40"))
        XCTAssertEqual(MeetingPageEdit.toggle(ticked, lines: line("Send the figures", in: ticked)), page)
        XCTAssertTrue(MeetingPageEdit.toggle(page, lines: line("Book a room", in: page))
            .contains("- [ ] Book a room · 1:00"))
    }

    func testALineWithoutABoxIsNotTicked() {
        XCTAssertEqual(MeetingPageEdit.toggle(page, lines: line("runs the warehouse", in: page)), page)
        XCTAssertEqual(MeetingPageEdit.toggle(page, lines: 500..<501), page)
    }

    // MARK: - Rewriting a line

    func testRewritingAToDoKeepsItsBoxOwnerAndTime() {
        let span = line("Send the figures", in: page)
        let edited = MeetingPageEdit.replace(page, lines: span, with: "Send the March figures")
        XCTAssertTrue(edited.contains("- [ ] Send the March figures — Person 2 · 0:40"))
        XCTAssertEqual(MeetingPage.lines(of: edited).count, MeetingPage.lines(of: page).count)
    }

    func testRewritingADecisionKeepsItsTickAndBoldLead() {
        let span = line("Budget", in: page)
        let block = MeetingPage.sourced(page).first { $0.lines == span }!.block
        XCTAssertEqual(MeetingPageEdit.editable(block), "Budget: keep it at ten")
        let edited = MeetingPageEdit.replace(page, lines: span, with: "Budget: keep it at twelve")
        XCTAssertTrue(edited.contains("- ✓ **Budget:** keep it at twelve · 2:10"), edited)
    }

    func testAParagraphBecomesOneLineAndEmptyTextTakesItOff() {
        let span = line("runs the warehouse", in: page)
        XCTAssertTrue(MeetingPageEdit.replace(page, lines: span, with: "Laura runs\nthe warehouse.")
            .contains("\nLaura runs the warehouse.\n"))
        let gone = MeetingPageEdit.replace(page, lines: line("Book a room", in: page), with: "  ")
        XCTAssertFalse(gone.contains("Book a room"))
        XCTAssertEqual(gone, MeetingPageEdit.delete(page, lines: line("Book a room", in: page)))
    }

    func testAParagraphOverSeveralLinesIsReplacedWhole() {
        let page = "## Summary\n\nFirst half\nsecond half.\n\n## To-dos\n"
        let paragraph = MeetingPage.sourced(page).first { if case .paragraph = $0.block { true } else { false } }!
        XCTAssertEqual(paragraph.lines, 2..<4)
        XCTAssertEqual(MeetingPageEdit.replace(page, lines: paragraph.lines, with: "One line."),
                       "## Summary\n\nOne line.\n\n## To-dos\n")
    }

    // MARK: - Adding a line

    func testAnAddedLineHasNoTimeAndGoesWhereItWasAsked() {
        let after = MeetingPageEdit.add(page, at: line("Book a room", in: page).upperBound,
                                        text: "Ring Marc", todo: true)
        let lines = MeetingPage.lines(of: after)
        let index = lines.firstIndex(of: "- [ ] Ring Marc")!
        XCTAssertTrue(lines[index - 1].contains("Book a room"))
        XCTAssertEqual(MeetingPageEdit.add(page, at: 3, text: "   ", todo: false), page)
        XCTAssertTrue(MeetingPageEdit.add(page, at: 9_999, text: "Last", todo: false).hasSuffix("- Last"))
    }

    func testAnAddedLineUnderABareHeadingLeavesABlankLineFirst() {
        let heading = line("## Open questions", in: page)
        let after = MeetingPageEdit.add(page, at: heading.upperBound, text: "Who pays?", todo: false)
        XCTAssertTrue(after.contains("## Open questions\n\n- Who pays?"), after)
    }

    func testACardGrowsAfterItsLastLineOrItsHeading() {
        let placed = MeetingPage.placed(page: page, header: "")
        let sections = MeetingPage.sections(placed).sections
        let todos = sections.first { $0.heading == MeetingFiles.todosHeading }!
        XCTAssertEqual(MeetingPageEdit.end(of: todos), line("Book a room", in: page).upperBound)
        let questions = sections.first { $0.heading == MeetingFiles.questionsHeading }!
        XCTAssertEqual(MeetingPageEdit.end(of: questions), line("## Open questions", in: page).upperBound)
    }

    // MARK: - Which lines are theirs

    func testOnlyALineTheyChangedOrTypedIsMarkedAsTheirs() {
        var edited = MeetingPageEdit.replace(page, lines: line("Send the figures", in: page), with: "Send it all")
        edited = MeetingPageEdit.add(edited, at: line("Book a room", in: edited).upperBound,
                                     text: "Mine", todo: true)
        let placed = MeetingPage.placed(page: edited, header: "", written: page)
        let changed = placed.filter(\.changed).compactMap { MeetingPageEdit.editable($0.block) }
        XCTAssertEqual(changed, ["Send it all", "Mine"])
        XCTAssertTrue(MeetingPage.placed(page: page, header: "", written: page).allSatisfy { !$0.changed })
        // Without the page as written, nothing is anyone's.
        XCTAssertTrue(MeetingPage.placed(page: edited, header: "").allSatisfy { !$0.changed })
    }

    func testEachLineKnowsItsPlaceOnThePage() {
        let placed = MeetingPage.placed(page: page, header: "")
        let figures = placed.first { MeetingPageEdit.editable($0.block)?.contains("Send the figures") == true }
        XCTAssertEqual(figures?.lines, line("Send the figures", in: page))
    }

    // MARK: - Title

    func testTheTitleIsTheFirstHeadingOrAddedAboveTheNotes() {
        XCTAssertTrue(MeetingPageEdit.retitled(page, as: "Warehouse sync").hasPrefix("# Warehouse sync\n\n## Summary"))
        XCTAssertEqual(MeetingPageEdit.retitled("## Summary\n\nWords", as: "Sync"), "# Sync\n\n## Summary\n\nWords")
        XCTAssertEqual(MeetingPageEdit.retitled(page, as: " "), page)
    }

    // MARK: - Names given after an edit

    func testNamingAgainKeepsTheirEditsAndNamesTheRestAfresh() {
        let before = room()
        var after = before
        after.name(2, as: "Laura")
        // Their own line names Person 2 too.
        var edited = MeetingPageEdit.add(page, at: line("Book a room", in: page).upperBound,
                                         text: "Thank Person 2", todo: true)
        edited = MeetingPageEdit.toggle(edited, lines: line("Send the figures", in: edited))
        let renamed = MeetingPageEdit.renamed(edited, written: page, from: before, to: after)
        XCTAssertTrue(renamed.contains("Laura runs the warehouse."), renamed)
        XCTAssertTrue(renamed.contains("- [x] Send the figures — Laura · 0:40"), renamed)
        XCTAssertTrue(renamed.contains("- [ ] Thank Laura"), renamed)

        // Named again: a name in a line they changed is swapped for the new one.
        var later = after
        later.name(2, as: "Laura Puig")
        let again = MeetingPageEdit.renamed(renamed, written: page, from: after, to: later)
        XCTAssertTrue(again.contains("- [ ] Thank Laura Puig"), again)
        XCTAssertFalse(again.contains("Puig Puig"), again)
        XCTAssertTrue(again.contains("Laura Puig runs the warehouse."), again)
    }

    func testAPageNobodyEditedIsNamedLikeBefore() {
        let before = room()
        var after = before
        after.name(2, as: "Laura")
        let named = MeetingNaming.apply(before, to: page)
        XCTAssertEqual(MeetingPageEdit.renamed(named, written: page, from: before, to: after),
                       MeetingNaming.apply(after, to: page))
    }

    func testANameTakenAwayGoesBackToTheLabel() {
        var before = room()
        before.name(2, as: "Laura")
        let after = room()
        XCTAssertEqual(MeetingPageEdit.swaps(from: before, to: after).map(\.0), ["Laura"])
        XCTAssertEqual(MeetingPageEdit.swaps(from: before, to: after).map(\.1), [MeetingRecord.personLabel(2)])
        XCTAssertEqual(MeetingPageEdit.swap("Laura", with: "Ana", in: "Laura and Lauran"), "Ana and Lauran")
    }

    // MARK: - On disk

    private func folder() throws -> (MeetingStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-edit-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingStore(root: root)
        let record = room()
        let folder = try store.makeFolder(for: record)
        try store.saveTranscript(record, in: folder)
        try store.saveNotes(page, in: folder)
        return (store, folder, root)
    }

    func testAnEditIsSavedToTheNotesFileAndThePageAsWrittenStays() throws {
        let (store, folder, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(store.notesWereEdited(in: folder))
        let edited = MeetingPageEdit.toggle(page, lines: line("Send the figures", in: page))
        try store.saveEditedNotes(edited, in: folder)
        XCTAssertEqual(store.notesPage(in: folder), edited)
        XCTAssertEqual(store.writtenNotes(in: folder), page)
        XCTAssertTrue(store.notesWereEdited(in: folder))

        XCTAssertEqual(try store.restoreWrittenNotes(in: folder), edited)
        XCTAssertEqual(store.notesPage(in: folder), page)
        XCTAssertFalse(store.notesWereEdited(in: folder))
    }

    func testNamingAfterAnEditKeepsTheEdit() throws {
        let (store, folder, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let edited = MeetingPageEdit.replace(page, lines: line("Book a room", in: page), with: "Book the big room")
        try store.saveEditedNotes(edited, in: folder)
        var record = try XCTUnwrap(store.loadRecord(in: folder))
        record.name(2, as: "Laura")
        try store.saveNames(of: record, in: folder)
        let saved = try XCTUnwrap(store.notesPage(in: folder))
        XCTAssertTrue(saved.contains("Book the big room"), saved)
        XCTAssertTrue(saved.contains("Laura runs the warehouse."), saved)
        // Names alone are not an edit.
        try store.restoreWrittenNotes(in: folder)
        XCTAssertFalse(store.notesWereEdited(in: folder))
    }

    func testRenamingTheCallChangesEveryFileAndCanBeTakenBack() throws {
        let (store, folder, root) = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveGivenTitle("Warehouse sync", in: folder)
        let record = try XCTUnwrap(store.loadRecord(in: folder))
        XCTAssertEqual(record.givenTitle, "Warehouse sync")
        XCTAssertEqual(MeetingFiles.title(of: record), "Warehouse sync")
        XCTAssertTrue(MeetingFiles.titleIsAName(record))
        XCTAssertTrue(store.notesPage(in: folder)?.hasPrefix("# Warehouse sync\n") == true)
        XCTAssertTrue(store.writtenNotes(in: folder)?.hasPrefix("# Warehouse sync\n") == true)
        let transcript = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcriptName),
                                    encoding: .utf8)
        XCTAssertTrue(transcript.hasPrefix("# Warehouse sync\n"))
        // A new title is not an edit of the notes.
        XCTAssertFalse(store.notesWereEdited(in: folder))

        try store.saveGivenTitle("", in: folder)
        XCTAssertNil(store.loadRecord(in: folder)?.givenTitle)
        XCTAssertTrue(store.notesPage(in: folder)?.hasPrefix("# Meeting in person\n") == true)
    }

    func testARecordFromBeforeTitlesReadsWithoutOne() throws {
        let data = try JSONEncoder().encode(room())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "givenTitle")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        XCTAssertNil(try decoder.decode(MeetingRecord.self, from: old).givenTitle)
    }
}
