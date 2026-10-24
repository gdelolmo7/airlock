import XCTest
@testable import AirlockCore

/// A notes page names its sections in the language its notes are written
/// in, and reads either language back the same way.
final class NotesHeadingLanguageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)

    private func record(_ languages: [String]) -> MeetingRecord {
        var record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, languages: languages)
        record.add(MeetingSegment(speaker: .them, start: 5, end: 10, text: String(repeating: "palabra ", count: 80)))
        return record
    }

    private let spanish = MeetingNotes(
        summary: "Hemos repasado el presupuesto del trimestre y las cifras de la campaña. El equipo cerrará "
            + "la factura de la feria el viernes y revisará los gastos de viaje antes de fin de mes.",
        todos: [.init(text: "Mandar la factura de la feria el viernes")],
        decisions: [.init(text: "La campaña sigue igual hasta diciembre")],
        questions: [.init(text: "¿Quién se encarga de los viajes?")])

    private let english = MeetingNotes(
        summary: "We went over the quarter's budget and the campaign figures. The team will close the fair's "
            + "invoice on Friday and go through the travel costs before the end of the month.",
        todos: [.init(text: "Send the fair's invoice on Friday")],
        decisions: [.init(text: "The campaign stays as it is until December")])

    func testSpanishNotesGetSpanishTitles() {
        let page = MeetingFiles.notesPage(for: record(["es_ES"]), notes: spanish)
        for title in ["## Resumen", "## Tareas", "## Decisiones", "## Preguntas abiertas"] {
            XCTAssertTrue(page.contains("\n\(title)\n"), title)
        }
        XCTAssertFalse(page.contains("## Summary"))
    }

    func testEnglishNotesKeepEnglishTitles() {
        let page = MeetingFiles.notesPage(for: record(["en_US"]), notes: english)
        XCTAssertTrue(page.contains("\n## Summary\n"))
        XCTAssertTrue(page.contains("\n## To-dos\n"))
    }

    /// The notes' own words decide, not what the call was listened in.
    func testTheNotesLanguageWinsOverTheRecogniser() {
        let page = MeetingFiles.notesPage(for: record(["es_ES"]), notes: english)
        XCTAssertTrue(page.contains("\n## Summary\n"))
    }

    func testSpanishTitlesReadBackAsAirlocksOwn() {
        let page = MeetingFiles.notesPage(for: record(["es_ES"]), notes: spanish)
        let headings = MeetingPage.blocks(of: page).compactMap { block -> String? in
            if case .heading(let text, level: 2) = block { return text }
            return nil
        }
        XCTAssertEqual(headings, [MeetingFiles.summaryHeading, MeetingFiles.todosHeading,
                                  MeetingFiles.decisionsHeading, MeetingFiles.questionsHeading])
        XCTAssertTrue(MeetingFiles.hasNotes(page))
    }

    func testEveryTitleRoundTrips() {
        for english in MeetingFiles.spanishHeadings.keys {
            XCTAssertEqual(MeetingFiles.canonicalHeading(MeetingFiles.headingWords(english, in: "es")), english)
            XCTAssertEqual(MeetingFiles.headingWords(english, in: "fr"), english)
        }
    }

    /// Only a section's own title is read as one: a topic called "Resumen"
    /// stays a topic.
    func testATopicIsNotASection() {
        let blocks = MeetingPage.blocks(of: "## Temas\n\n### Resumen\n")
        XCTAssertEqual(blocks, [.heading(MeetingFiles.topicsHeading, level: 2), .heading("Resumen", level: 3)])
    }

    /// "Your notes" in Spanish is still the person's own words.
    func testYourNotesInSpanishAreYours() {
        let placed = MeetingPage.placed(MeetingPage.blocks(of: "## Tus notas\n\n- llamar a Ana · 0:30\n"))
        XCTAssertEqual(placed.last?.isYours, true)
    }
}
