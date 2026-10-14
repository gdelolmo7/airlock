import XCTest
@testable import AirlockCore

/// What a call that moved into another language leaves behind: the record,
/// the notes written from it, the transcript's divider and the questions
/// answered from it.
///
/// The call: both sides in Spanish, then the other side in Catalan from
/// 10:12, with the Spanish take kept running beside it as the shadow.
final class CallLanguageSwitchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600) // 2026-10-08 14:10 UTC
    private let seam: TimeInterval = 612 // 10:12

    private func line(_ speaker: MeetingSpeaker, _ at: TimeInterval, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: at, end: at + 5, text: text)
    }

    /// Notes are written by a model that reads Spanish and not Catalan.
    private let canRead: @Sendable (String) -> Bool = { CallLanguage.code(of: $0) != "ca" }

    private func call(withShadow: Bool = true) -> MeetingRecord {
        var record = MeetingRecord(bundleID: "com.google.Chrome", appName: "Chrome", site: .googleMeet,
                                   startedAt: start, languages: ["es_ES", "ca_ES"])
        record.listen(.me, from: 0, in: "es_ES")
        record.listen(.them, from: 3, in: "es_ES")
        for segment in [line(.me, 5, "Buenos días a todos, empezamos con el presupuesto."),
                        line(.them, 10, "Perfecto, yo traigo las cifras del trimestre."),
                        line(.them, 600, "Ahora os cuento cómo va la campaña."),
                        // What the Spanish take made of the Catalan, before the switch.
                        line(.them, seam, "La campaña va molt bé este mes."),
                        line(.them, 620, "Hem tancat tres clientes nuevos.")] {
            record.add(segment)
        }
        record.switchLanguage(of: .them, at: seam, to: "ca_ES",
                              lines: [line(.them, seam, "La campanya va molt bé aquest mes."),
                                      line(.them, 620, "Hem tancat tres clients nous.")],
                              keptAs: withShadow ? "es_ES" : nil)
        record.add(line(.them, 660, "El pressupost de la fira el tanquem divendres."))
        if withShadow {
            record.addShadow(MeetingShadowLine(segment: line(.them, 661, "El presupuesto de la feria lo cerramos el viernes."),
                                               language: "es_ES"))
        }
        record.add(line(.me, 700, "Vale, entonces el viernes mando yo la factura."))
        return record
    }

    // MARK: - The record

    func testASwitchReplacesOneSideFromTheSeam() {
        let record = call()
        XCTAssertEqual(record.segments.filter { $0.speaker == .them }.map(\.start), [10, 600, seam, 620, 660])
        XCTAssertEqual(record.segments.first { $0.start == seam }?.text, "La campanya va molt bé aquest mes.")
        XCTAssertEqual(record.segments.filter { $0.speaker == .me }.count, 2, "the other side is untouched")
        XCTAssertEqual(record.shadow.map(\.segment.start), [seam, 620, 661],
                       "what Spanish heard from the seam is kept as the shadow")
        XCTAssertEqual(record.shadow.map(\.language), ["es_ES", "es_ES", "es_ES"])
        XCTAssertEqual(record.listenings, [
            MeetingListening(speaker: .me, from: 0, language: "es_ES"),
            MeetingListening(speaker: .them, from: 3, language: "es_ES"),
            MeetingListening(speaker: .them, from: seam, language: "ca_ES"),
        ])
    }

    /// Back into a language the writer reads: the shadow from there on is
    /// what is shown now, and nothing is kept behind it.
    func testSwitchingBackKeepsNoShadow() {
        var record = call()
        record.switchLanguage(of: .them, at: 650, to: "es_ES",
                              lines: [line(.them, 661, "El presupuesto de la feria lo cerramos el viernes.")])
        XCTAssertEqual(record.segments.filter { $0.speaker == .them }.map(\.start), [10, 600, seam, 620, 661])
        XCTAssertEqual(record.shadow.map(\.segment.start), [seam, 620], "the Catalan stretch keeps its shadow")
        XCTAssertEqual(record.listenings.filter { $0.speaker == .them }.map(\.language),
                       ["es_ES", "ca_ES", "es_ES"])
    }

    func testTheSameLanguageAgainIsNoChange() {
        var record = MeetingRecord(bundleID: "a", appName: "A", startedAt: start)
        record.listen(.them, from: 0, in: "es_ES")
        record.listen(.them, from: 90, in: "es_ES")
        XCTAssertEqual(record.listenings.count, 1)
    }

    /// A `meeting.json` from before listenings and the shadow still opens.
    func testARecordWithoutTheNewFieldsStillLoads() throws {
        let json = """
            {
              "appName" : "Chrome",
              "bundleID" : "com.google.Chrome",
              "languages" : [ "es_ES" ],
              "segments" : [ { "end" : 5, "speaker" : "them", "start" : 3, "text" : "Hola, ¿me oís?" } ],
              "startedAt" : "2026-10-08T14:10:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MeetingRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.segments.count, 1)
        XCTAssertTrue(record.listenings.isEmpty)
        XCTAssertTrue(record.shadow.isEmpty)
        // And such a call is written from as heard.
        let source = MeetingNotesSource(record, canRead: canRead)
        XCTAssertEqual(source.record, record)
        XCTAssertNil(source.line)
    }

    func testListeningsAndTheShadowRoundTrip() throws {
        let record = call()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingRecord.self, from: encoder.encode(record)), record)
    }

    // MARK: - What the notes are written from

    func testTheCatalanStretchIsWrittenFromTheSpanishListening() {
        let source = MeetingNotesSource(call(), canRead: canRead)
        let them = source.record.segments.filter { $0.speaker == .them }
        XCTAssertEqual(them.map(\.text), [
            "Perfecto, yo traigo las cifras del trimestre.",
            "Ahora os cuento cómo va la campaña.",
            "La campaña va molt bé este mes.",
            "Hem tancat tres clientes nuevos.",
            "El presupuesto de la feria lo cerramos el viernes.",
        ])
        XCTAssertEqual(source.record.segments.filter { $0.speaker == .me }.count, 2)
        XCTAssertEqual(source.record.languages, ["es_ES"])
        XCTAssertEqual(source.line,
                       "Written from a Spanish listening — Apple's notes writer can't read Catalan yet.")
        XCTAssertTrue(source.unreadable.isEmpty)
        XCTAssertEqual(source.readable.count, source.record.spokenSegments.count)
    }

    /// A line of notes says when it was said, and the window opens the
    /// transcript there: written from the shadow, it still lands on the
    /// Catalan turn said at that moment.
    func testCitationsFromTheShadowLandOnTheShownTurn() {
        let record = call()
        let source = MeetingNotesSource(record, canRead: canRead)
        let shown = MeetingTimeline.entries(of: record)
        let numbered = NumberedTranscript(source.record)
        guard let fair = numbered.turns.first(where: { $0.text.contains("feria") }) else {
            return XCTFail("the shadow's line is numbered")
        }
        XCTAssertEqual(fair.start, 661)
        guard let index = MeetingTimeline.spoken(at: fair.start, in: shown),
              case .speech(let turn, _) = shown[index] else { return XCTFail("lands on a turn") }
        XCTAssertEqual(turn.start, 660)
        XCTAssertTrue(turn.text.contains("pressupost de la fira"))

        guard let campaign = numbered.turns.first(where: { $0.start == seam }),
              let at = MeetingTimeline.spoken(at: campaign.start, in: shown),
              case .speech(let opening, _) = shown[at] else { return XCTFail("the seam's turn") }
        XCTAssertEqual(opening.start, seam)
        XCTAssertTrue(opening.text.hasPrefix("La campanya"))
    }

    /// Nothing to stand in: the Catalan is left as heard for the notes, and
    /// left out of what questions are answered from.
    func testWithoutAShadowTheStretchIsNamedUnreadable() {
        let record = call(withShadow: false)
        let source = MeetingNotesSource(record, canRead: canRead)
        XCTAssertEqual(source.record.segments, record.segments)
        XCTAssertNil(source.line)
        XCTAssertEqual(source.unreadable, ["ca_ES"])
        XCTAssertFalse(source.readable.contains { $0.text.contains("campanya") })
        XCTAssertTrue(source.readable.contains { $0.text.contains("cifras") })
    }

    /// A model that reads everything changes nothing.
    func testAReadableCallIsWrittenFromAsHeard() {
        let record = call()
        let source = MeetingNotesSource(record, canRead: { _ in true })
        XCTAssertEqual(source.record, record)
        XCTAssertNil(source.line)
    }

    func testTheNotesPageSaysWhatItWasWrittenFrom() {
        let source = MeetingNotesSource(call(), canRead: canRead)
        let page = MeetingFiles.notesPage(for: call(), notes: MeetingNotes(summary: "Se habló del presupuesto."),
                                          writtenFrom: source.line, timeZone: TimeZone(identifier: "UTC")!)
        let lines = page.components(separatedBy: "\n")
        XCTAssertEqual(lines[4], "_Written from a Spanish listening — Apple's notes writer can't read Catalan yet._")
        XCTAssertEqual(lines[6], "## Summary")
    }

    // MARK: - The divider

    func testTheTranscriptMarksTheSwitchOnce() {
        var record = call()
        // The microphone follows into Catalan too, a little later.
        record.switchLanguage(of: .me, at: 640, to: "ca_ES", lines: [])
        let entries = MeetingTimeline.entries(of: record)
        let dividers = entries.compactMap { entry -> MeetingListening? in
            if case .language(let listening) = entry { return listening }
            return nil
        }
        XCTAssertEqual(dividers, [MeetingListening(speaker: .them, from: seam, language: "ca_ES")],
                       "no divider for where each side started, one for both sides following")
        guard let at = entries.firstIndex(where: { if case .language = $0 { true } else { false } }) else {
            return XCTFail("a divider")
        }
        guard case .speech(let before, _) = entries[at - 1], case .speech(let after, _) = entries[at + 1] else {
            return XCTFail("between two turns")
        }
        XCTAssertEqual(before.start, 600, "the Spanish turn ends at the divider")
        XCTAssertFalse(before.text.contains("campanya"))
        XCTAssertEqual(after.start, seam)
        XCTAssertEqual(MeetingTimeline.languageLabel(dividers[0]), "Catalan from 10:12")
    }

    func testTheTranscriptFileSaysItInItalics() {
        let transcript = MeetingFiles.transcript(of: call(), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(transcript.contains("\n_Catalan from 10:12_\n"))
        XCTAssertLessThan(transcript.range(of: "campaña.")!.lowerBound,
                          transcript.range(of: "_Catalan from 10:12_")!.lowerBound)
        XCTAssertLessThan(transcript.range(of: "_Catalan from 10:12_")!.lowerBound,
                          transcript.range(of: "La campanya")!.lowerBound)
    }

    func testGoingBackIsMarkedToo() {
        var record = call()
        record.switchLanguage(of: .them, at: 690, to: "es_ES", lines: [line(.them, 690, "Volvemos al castellano.")])
        XCTAssertEqual(MeetingTimeline.dividers(of: record).map(MeetingTimeline.languageLabel),
                       ["Catalan from 10:12", "Spanish from 11:30"])
    }

    // MARK: - The panel

    func testThePanelShowsTheDividerAmongItsLines() {
        let lines = CallNotesPanel.recentLines(of: call(), count: 4)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map(\.isDivider), [true, false, false, false])
        XCTAssertEqual(lines[0].text, "Catalan from 10:12")
        XCTAssertEqual(lines.last?.speaker, "You")
    }

    /// Between two lines shown, wherever it falls.
    func testThePanelDividerSitsBetweenLines() {
        let lines = CallNotesPanel.recentLines(of: call(), count: 6)
        XCTAssertEqual(lines.map(\.isDivider), [false, true, false, false, false, false])
        XCTAssertEqual(lines[0].text, "Ahora os cuento cómo va la campaña.")
        XCTAssertEqual(lines[2].text, "La campanya va molt bé aquest mes.")
    }

    /// Long after the switch, a divider above every line shown says nothing.
    func testAnOldDividerLeavesThePanel() {
        var record = call()
        for (index, at) in [1000.0, 1010, 1020, 1030].enumerated() {
            record.add(line(.them, at, "Una línea más en catalán, número \(index)."))
        }
        let lines = CallNotesPanel.recentLines(of: record, count: 4)
        XCTAssertFalse(lines.contains(where: \.isDivider))
        XCTAssertEqual(lines.count, 4)
    }

    // MARK: - Questions about the call

    private struct Folders: CallFolders {
        var calls: [String: MeetingRecord]
        func stamps() -> [String: Date] { calls.mapValues { _ in Date(timeIntervalSince1970: 1_000) } }
        func record(in folder: String) -> MeetingRecord? { calls[folder] }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testQuestionsAreAnsweredFromTheShadow() {
        var index = CallSearchIndex(canRead: canRead)
        index.refresh(from: Folders(calls: ["call": call()]))
        let found = index.search(CallQuery("presupuesto de la feria", now: start.addingTimeInterval(3600),
                                           calendar: calendar))
        XCTAssertTrue(found.contains { $0.text.contains("El presupuesto de la feria lo cerramos") })
        XCTAssertFalse(found.contains { $0.text.contains("pressupost de la fira") })
    }

    func testAnUnreadableCallSaysSo() {
        var index = CallSearchIndex(canRead: canRead)
        index.refresh(from: Folders(calls: ["call": call(withShadow: false)]))
        let query = CallQuery("pressupost fira", now: start.addingTimeInterval(3600), calendar: calendar)
        XCTAssertTrue(index.search(query).isEmpty)
        XCTAssertEqual(index.unreadable(for: query), "ca_ES")
        XCTAssertEqual(CallAnswer.miss(.unreadable("ca_ES"), language: "English"),
                       "I couldn't find that. Part of your calls is in Catalan, which Apple's model can't read yet.")
        XCTAssertEqual(CallAnswer.miss(.unreadable("ca_ES"), language: "Spanish"),
                       "No he encontrado nada de eso. Parte de tus llamadas está en catalán, "
                       + "y el modelo de Apple todavía no puede leerlo.")
    }

    func testAReadableCallHasNothingUnreadable() {
        var index = CallSearchIndex(canRead: canRead)
        index.refresh(from: Folders(calls: ["call": call()]))
        XCTAssertNil(index.unreadable(for: CallQuery("nada", now: start.addingTimeInterval(3600),
                                                      calendar: calendar)))
    }
}
