import AirlockCore
import Foundation
import FoundationModels
import XCTest
@testable import AirlockApp

/// Opt-in, and not hermetic: runs Apple's on-device model on THIS Mac.
///
///     AIRLOCK_MODEL_PROBE=1 swift test --filter CallNotesModelProbe
///
/// Writes notes for two made-up three-minute calls, one in English and one
/// in Spanish, and prints the notes page and the log for a person to read:
/// whether every line points at the right moment, whether the owners are
/// the ones named on the call, whether anything was invented, and whether
/// the Spanish notes stay in Spanish. Each call is written twice, without
/// the second look and with it (`CallNotesChecks`), to show which owners and
/// open questions it took off and what it costs in seconds. The model's
/// wording changes between macOS versions, so wording is not asserted; only
/// what the checks in Core guarantee is.
///
/// It also measures, in the model's own tokens, the biggest part a call can
/// be cut into, to show the part size leaves room for the answer.
@MainActor
final class CallNotesModelProbe: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["AIRLOCK_MODEL_PROBE"] == "1"
    private static let skipReason = "Runs Apple's on-device model; set AIRLOCK_MODEL_PROBE=1 to run it."

    func testEnglishCall() async throws {
        try XCTSkipUnless(Self.enabled, Self.skipReason)
        try await probe(Self.english)
    }

    func testSpanishCall() async throws {
        try XCTSkipUnless(Self.enabled, Self.skipReason)
        try await probe(Self.spanish)
    }

    func testTheBiggestPartFitsTheModel() async throws {
        try XCTSkipUnless(Self.enabled, Self.skipReason)
        guard #available(macOS 26.4, *) else { throw XCTSkip("Counting tokens needs macOS 26.4.") }
        let model = SystemLanguageModel.default
        try XCTSkipUnless(model.isAvailable, "Apple Intelligence isn't available on this Mac.")
        let instructions = try await model.tokenCount(for: Instructions(CallNotesPrompts.factsInstructions))
        let schema = try await model.tokenCount(for: CallPartFacts.generationSchema)
        let answerCap = MeetingSummarizer.partAnswerTokens
        print("PROBE context \(model.contextSize) tokens; rules \(instructions), answer shape \(schema), "
              + "answer cap \(answerCap), part budget \(NumberedTranscript.chunkBudget) chars")
        for (record, language) in [(Self.english, "English"), (Self.spanish, "Spanish")] {
            let full = Self.filled(record, to: NumberedTranscript.chunkBudget)
            let chunk = try XCTUnwrap(NumberedTranscript(full).chunks().first)
            // Everything else a part's prompt can carry, at its cap.
            let jots = (0..<30).map { MeetingJot(at: Double($0), text: "a line typed during the call, quite long") }
            let prompt = CallNotesPrompts.facts(
                for: chunk, part: 2, of: 3, language: language, people: MeetingPeople(record: full), jots: jots)
            let promptTokens = try await model.tokenCount(for: prompt)
            let chunkTokens = try await model.tokenCount(for: chunk.text)
            let total = instructions + schema + promptTokens
            print("PROBE \(language): a full part, \(chunk.text.count) chars = \(chunkTokens) tokens "
                  + "(\(String(format: "%.2f", Double(chunk.text.count) / Double(chunkTokens))) chars a token); "
                  + "rules + shape + prompt = \(total), + answer cap = \(total + answerCap) of \(model.contextSize)")
            XCTAssertLessThanOrEqual(total + answerCap, model.contextSize)

            // How long a real answer to a dense part is.
            let session = LanguageModelSession(instructions: CallNotesPrompts.factsInstructions)
            do {
                let response = try await session.respond(
                    to: prompt, generating: CallPartFacts.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: answerCap))
                let answer = try await model.tokenCount(for: response.content.generatedContent.jsonString)
                let facts = response.content
                print("PROBE \(language): answer \(answer) tokens for \(facts.decisions.count) decision(s), "
                      + "\(facts.todos.count) to-do(s), \(facts.questions.count) question(s), \(facts.topics.count) topic(s)")
            } catch {
                print("PROBE \(language): the full part failed: \(error)")
            }
        }
    }

    private func probe(_ record: MeetingRecord) async throws {
        var started = Date()
        let before = await MeetingSummarizer.notes(for: record, withSecondLook: false) { _ in }
        let withoutSeconds = Date().timeIntervalSince(started)
        var lines: [String] = []
        started = Date()
        let outcome = await MeetingSummarizer.notes(for: record) { lines.append($0) }
        let withSeconds = Date().timeIntervalSince(started)
        print("PROBE log:\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
        print(String(format: "PROBE without the second look %.1fs, with it %.1fs", withoutSeconds, withSeconds))
        switch outcome {
        case .unavailable(let reason):
            print("PROBE no notes: \(reason)")
            print(MeetingFiles.notesPage(for: record, notes: nil, unavailableReason: reason))
            throw XCTSkip("No notes: \(reason)")
        case .notes(let notes):
            print("PROBE notes page:\n" + MeetingFiles.notesPage(for: record, notes: notes))
            let transcript = NumberedTranscript(record)
            let spoken = Set(transcript.turns.map(\.id))
            let all = notes.todos + notes.decisions + notes.questions + notes.keyPoints
            for item in all {
                XCTAssertFalse(item.sources.isEmpty, "every line has a source: \(item.text)")
                XCTAssertTrue(Set(item.sources).isSubset(of: spoken), item.text)
                XCTAssertNotNil(item.at, item.text)
            }
            let known: Set<String?> = [nil, "You", record.otherName]
            for todo in notes.todos { XCTAssertTrue(known.contains(todo.owner), "owner \(todo.owner ?? "-")") }
            XCTAssertFalse(notes.summary.isEmpty, "the final step should write a summary")
            if case .notes(let before) = before { compare(before, notes) }
        }
    }

    /// The to-dos and open questions without the second look and with it.
    /// The model reads greedily, so the parts come back the same both times
    /// and only the second look can differ: it may take an owner off, or an
    /// open question out, and nothing else.
    private func compare(_ before: MeetingNotes, _ after: MeetingNotes) {
        var lines = ["PROBE second look, before -> after:"]
        for todo in before.todos {
            let now = after.todos.first { $0.text == todo.text }
            lines.append("  to-do: \(todo.text) — \(todo.owner ?? "nobody") -> "
                         + (now.map { $0.owner ?? "nobody" } ?? "not in the second run"))
        }
        for question in before.questions {
            let open = after.questions.contains { $0.text == question.text }
            lines.append("  open question: \(question.text) -> \(open ? "still open" : "answered, taken out")")
        }
        print(lines.joined(separator: "\n"))
        guard before.todos.map(\.text) == after.todos.map(\.text) else {
            print("PROBE the parts came back different in the two runs, so they are not compared")
            return
        }
        for (old, new) in zip(before.todos, after.todos) {
            XCTAssertTrue(new.owner == nil || new.owner == old.owner, "the second look only takes owners off")
        }
        XCTAssertTrue(Set(after.questions.map(\.text)).isSubset(of: before.questions.map(\.text)),
                      "the second look only takes questions out")
    }

    /// The call's own lines, repeated with fresh times until the transcript
    /// is as long as one part can be: the worst case for the model's window.
    private static func filled(_ record: MeetingRecord, to budget: Int) -> MeetingRecord {
        var segments: [MeetingSegment] = []
        var offset: TimeInterval = 0
        while NumberedTranscript(MeetingRecord(bundleID: record.bundleID, appName: record.appName,
                                               startedAt: record.startedAt, segments: segments,
                                               event: record.event)).chunks(budget: .max)
            .first.map({ $0.text.count < budget * 2 }) ?? true {
            segments += record.segments.map {
                MeetingSegment(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset, text: $0.text)
            }
            offset += 200
        }
        return MeetingRecord(bundleID: record.bundleID, appName: record.appName, startedAt: record.startedAt,
                             segments: segments, event: record.event)
    }

    // MARK: - The calls

    private static let start = Date(timeIntervalSince1970: 1_791_468_600)

    /// Lines 10.5 s apart, each 7 s long: far enough apart that the echo
    /// filter (`MeetingEcho`) never takes a "You" line that repeats the
    /// line before it for the speakers' sound coming back.
    private static func call(_ title: String, with other: String, _ lines: [(Bool, String)],
                             jot: MeetingJot, mark: TimeInterval) -> MeetingRecord {
        var record = MeetingRecord(
            bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start, endedAt: start + 185,
            segments: lines.enumerated().map { index, line in
                let at = 3 + Double(index) * 10.5
                return MeetingSegment(speaker: line.0 ? .me : .them, start: at, end: at + 7, text: line.1)
            },
            event: MeetingEvent(title: title, start: start, attendees: [other]))
        record.jot(jot.text, at: jot.at)
        record.mark(at: mark)
        return record
    }

    /// A decision (launch without the blog), a to-do with a named owner
    /// (Mark sends the copy by Wednesday), one with none (check the
    /// analytics), an open question (legal review), a note typed during the
    /// call (at the question) and a mark on the decision.
    static let english = call("Website relaunch", with: "Mark Chen", [
        (false, "Hi, thanks for making time. I wanted to go through the website relaunch before the end of the month."),
        (true, "Sure, happy to. Where are we with the new design?"),
        (false, "The designs are finished and approved. The big open point is whether we launch with the blog or without it."),
        (true, "Honestly, the blog posts aren't ready. If we wait for them, we slip at least two weeks."),
        (false, "Same feeling here. So let's launch without the blog and add it in November."),
        (true, "Agreed, we launch without the blog and add it in November."),
        (false, "Great. I'll send the final copy to the developers by Wednesday, so they have everything they need."),
        (true, "Perfect. What about the pricing page?"),
        (false, "That's the part I'm unsure about. Does the pricing page need a legal review before it goes live? I really don't know."),
        (true, "Neither do I. Nobody has told us either way."),
        (false, "Let's leave that open for now and see if someone knows."),
        (true, "Also, somebody needs to check the analytics setup before launch, otherwise we won't see any traffic numbers."),
        (false, "Good point, that has to happen before launch."),
        (true, "The launch date stays the twenty-eighth, right?"),
        (false, "Yes, the twenty-eighth, nothing changes there."),
        (true, "Great. I think that's everything for today. Thanks, Mark."),
        (false, "Thanks, talk soon."),
    ], jot: MeetingJot(at: 91, text: "pricing page legal review?"), mark: 55)

    /// The same shape in Spanish: the event on 14 November (decided),
    /// Lucía books the room before Friday, invitations with no owner yet,
    /// who pays for the catering (open).
    static let spanish = call("Evento de clientes", with: "Lucía Fernández", [
        (false, "Hola, gracias por conectarte. Quería repasar el evento de clientes de noviembre."),
        (true, "Claro. ¿Ya tenemos fecha?"),
        (false, "Teníamos dos opciones, el siete o el catorce de noviembre. El siete coincide con la feria, así que es complicado."),
        (true, "Entonces mejor el catorce. Así tenemos más tiempo para preparar todo."),
        (false, "De acuerdo, queda decidido: el evento será el catorce de noviembre en Madrid."),
        (true, "Perfecto. ¿Quién se encarga de reservar la sala?"),
        (false, "Yo me encargo. Reservo la sala antes del viernes y te confirmo."),
        (true, "Genial. También hay que mandar las invitaciones a los clientes, pero todavía no sabemos quién lo hará."),
        (false, "Sí, eso lo vemos la semana que viene."),
        (true, "Otra cosa: ¿quién paga el catering? ¿Lo pagamos nosotros o lo cubre el patrocinador?"),
        (false, "Buena pregunta. No lo sé, el contrato con el patrocinador no lo dice claramente."),
        (true, "Vale, lo dejamos abierto hasta que alguien lo aclare."),
        (false, "Sobre el formato, pensaba en tres charlas cortas y luego un cóctel para que la gente hable."),
        (true, "Me parece bien, aunque podemos decidir el formato más adelante."),
        (false, "Perfecto, entonces lo hablamos otro día."),
        (true, "Muy bien. Gracias, Lucía, hablamos pronto."),
        (false, "¡Hasta luego!"),
    ], jot: MeetingJot(at: 102, text: "catering: ¿patrocinador?"), mark: 55)
}
