import AirlockCore
import Foundation
import FoundationModels

// What the model fills in. Turned into `MeetingDraft` straight away: the
// checks that decide what is kept are in Core (`MeetingLedger`), where they
// are tested without a model.
//
// The model writes the fields in the order they are declared. Text first:
// with the lines first, test calls came back with "Talk soon" as a to-do.
// Every list has a cap, so one runaway list can't use up the answer: on a
// test the model cited fifty lines for one topic, and on a long call one
// list repeated the same two lines until the answer was cut off and could
// not be read. Either way the part was lost, and with it minutes of notes.

@Generable
struct CallFact {
    @Guide(description: "One short line.")
    var text: String
    @Guide(description: "IDs of the transcript lines it comes from, like S12: the ID alone.", .maximumCount(4))
    var sources: [String]

    var draft: MeetingDraft.Fact { MeetingDraft.Fact(text: text, sources: sources) }
}

@Generable
struct CallTodo {
    @Guide(description: "What will be done, as a short instruction.")
    var task: String
    @Guide(description: "Who will do it: You, or a name from the list of people, only if the transcript says that person will do it. Empty if it says somebody or we, or nobody took it on.")
    var owner: String
    @Guide(description: "When it is due, in the words used in the meeting, like \"by Friday\". Empty if not said.")
    var due: String
    @Guide(description: "IDs of the transcript lines it comes from, like S12: the ID alone.", .maximumCount(4))
    var sources: [String]

    var draft: MeetingDraft.Todo { MeetingDraft.Todo(task: task, owner: owner, due: due, sources: sources) }
}

/// One part of the call, as lists of what was found in it.
@Generable
struct CallPartFacts {
    @Guide(description: "What the people in the meeting clearly agreed or decided. Not tasks, and not things only discussed.",
           .maximumCount(5))
    var decisions: [CallFact]
    @Guide(description: "Tasks somebody said they will do after the meeting.", .maximumCount(6))
    var todos: [CallTodo]
    @Guide(description: "Questions raised and left unanswered.", .maximumCount(4))
    var questions: [CallFact]
    @Guide(description: "What was talked about, one short line per subject.", .maximumCount(5))
    var topics: [CallFact]

    var draft: MeetingDraft {
        MeetingDraft(decisions: decisions.map(\.draft), todos: todos.map(\.draft),
                     questions: questions.map(\.draft), topics: topics.map(\.draft))
    }
}

@Generable
struct CallKeyPoint {
    @Guide(description: "One short line.")
    var text: String
    @Guide(description: "IDs of the notes it comes from, like F3. At least one of them is a topic.",
           .maximumCount(6))
    var sources: [String]
}

/// The last step: the summary and key points, from checked lines only.
@Generable
struct CallWrapUp {
    @Guide(description: "One full plain sentence for someone who missed it: what the meeting was for.")
    var purpose: String
    @Guide(description: "One or two plain sentences on what came out of it, naming two or three of the decisions, to-dos or open questions from the notes by what they are. A to-do is still to be done, not done.")
    var outcome: String
    @Guide(description: "A name for the meeting by what it was about, in two to six words, as someone would file it. No quotes, no full stop, no date.")
    var title: String
    @Guide(description: "Short lines on the topics discussed, saying what the decisions, to-dos and open questions do not already say.",
           .maximumCount(5))
    var keyPoints: [CallKeyPoint]

    /// Asked in two halves: asked for in one, Apple's model wrote what the
    /// meeting was for and then only that "tasks were agreed and questions
    /// remain open", naming none of them.
    var summary: String {
        [purpose, outcome].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Writes a call's notes with Apple's on-device model. Nothing leaves the Mac.
///
/// In two steps (`CallNotesPrompts`): each part of the numbered transcript
/// is read on its own, a fresh session each, and what the model lists there
/// is checked against the transcript before it is believed; then one last
/// session writes the summary and key points from the checked lines alone.
/// A part the model fails on climbs a short ladder (`CallNotesLadder`):
/// tried again, halved, or asked for plain lines, and what is still missing
/// after that is named on the page by its minutes (`CallNotesCoverage`),
/// never left out quietly. Between the two steps, a second look
/// (`CallNotesChecks`) asks again, in short questions about a few lines
/// each, about every owner and every open question, so the summary is
/// written from owners that were confirmed. If the last step fails, the
/// checked lines are saved without a summary, the topics standing in as
/// key points: plain notes beat none.
///
/// The log gets counts, kinds, part numbers and times only, never a word
/// of the call, and never an error's own text, which can quote one.
@MainActor
enum MeetingSummarizer {
    enum Outcome {
        case notes(MeetingNotes)
        /// No notes, and why, in words for the notes page.
        case unavailable(String)
    }

    /// Room for the answers. A cap, not a reservation: most answers are far
    /// shorter, and the transcript budget assumes they are.
    static let partAnswerTokens = 1_000
    private static let wrapUpAnswerTokens = 600
    /// Plain lines say the same as a part's form in fewer words.
    private static let plainTextAnswerTokens = 600

    /// How a part is asked the first time: the likeliest answer, so the
    /// same call gives the same notes.
    private static let partOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: partAnswerTokens)
    /// How a part whose answer could not be read is asked again. The one
    /// seen was a loop, a list repeating two lines until the answer was cut
    /// off, and asked the same way the model loops the same way. A little
    /// chance, low and seeded so a rerun reads the same, lets it step out.
    private static let retryOptions = GenerationOptions(
        sampling: .random(top: 40, seed: 57), temperature: 0.5, maximumResponseTokens: partAnswerTokens)
    /// A second-look answer is a word, a letter or a name. A longer reply
    /// is cut off, and is still read from its first words.
    private static let checkAnswerTokens = 12

    /// `withSecondLook` is off only in the model probe, to show the notes
    /// with and without it.
    static func notes(for record: MeetingRecord, withSecondLook: Bool = true,
                      log: (String) -> Void) async -> Outcome {
        let started = Date()
        let transcript = NumberedTranscript(record)
        let words = transcript.wordCount
        // Checked before the model's availability: a call with nothing said
        // gets the same honest page on every Mac.
        guard words >= MeetingNotes.minimumWords else {
            log("summary: \(words) word(s), too few for notes")
            return .notes(MeetingNotes())
        }
        let availability = CleanupService().availability
        guard availability.isReady else {
            return .unavailable(availability.message(feature: "call notes")
                                ?? "Apple Intelligence isn't available.")
        }
        let check = CallLanguage.check(record)
        log(check.logLine)
        let language = check.decision?.name
        let chunks = transcript.chunks()
        let jots = CallNotesPrompts.jots(record.jots, for: chunks)
        log("summary: \(chunks.count) part(s), \(transcript.turns.count) turn(s), "
            + "\(record.jots.count) jot(s), \(record.marks.count) mark(s), \(language ?? "language unknown")")

        var reading = Reading(ledger: MeetingLedger(transcript: transcript, people: MeetingPeople(record: record)))
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return .unavailable("Notes were stopped.") }
            var ladder = CallNotesLadder()
            let answered = reading.answered
            let tally = await read(chunk, named: "\(index + 1)", jots: jots[index], part: index + 1,
                                   of: chunks.count, language: language, ladder: &ladder,
                                   reading: &reading, log: log)
            if reading.answered > answered {
                log("summary: part \(index + 1): kept \(tally.kept), dropped \(tally.dropped)")
            }
        }
        let unwritten = reading.coverage.unwritten
        if !unwritten.isEmpty {
            log("summary: \(unwritten.count) stretch\(unwritten.count == 1 ? "" : "es") unwritten ("
                + unwritten.map { "\(MeetingFiles.clock($0.start))–\(MeetingFiles.clock($0.end))" }
                    .joined(separator: ", ") + ")")
        }
        let failed = reading.lastError.map(describe) ?? "the model gave no answer."
        guard reading.answered > 0 else { return .unavailable(failed) }

        if withSecondLook { await secondLook(&reading.ledger, log: log) }
        var notes = await wrapUp(reading.ledger, language: language, log: log)
        notes.unwritten = unwritten
        log(String(format: "summary: %d to-do(s), %d decision(s), %d question(s), %d key point(s) in %.1fs",
                   notes.todos.count, notes.decisions.count, notes.questions.count, notes.keyPoints.count,
                   Date().timeIntervalSince(started)))
        // "Nothing stood out" is only true of a call that was read in full.
        guard !notes.isEmpty else {
            return .unavailable(unwritten.isEmpty ? "nothing in the call stood out to the model." : failed)
        }
        return .notes(notes)
    }

    /// What reading the parts has gathered so far.
    private struct Reading {
        var ledger: MeetingLedger
        var coverage = CallNotesCoverage()
        /// Pieces the model answered, in any of the ladder's ways.
        var answered = 0
        var lastError: Error?
    }

    /// One piece of a part, its lines checked into the ledger, climbing the
    /// ladder (`CallNotesLadder`) when the model fails on it. Pieces are
    /// read in order, a half before the next, so the ledger keeps the
    /// call's order and each piece sees what the one before it found.
    /// `name` is for the log: the part's number, then a letter per half,
    /// so "7b" is part 7's second half and "7ba" the first half of that.
    private static func read(_ chunk: TranscriptChunk, named name: String, jots: [MeetingJot],
                             part: Int, of count: Int, language: String?, splits: Int = 0,
                             retried: Bool = false, ladder: inout CallNotesLadder,
                             reading: inout Reading, log: (String) -> Void) async -> MeetingLedger.Tally {
        let prompt = CallNotesPrompts.facts(for: chunk, part: part, of: count, language: language,
                                            people: reading.ledger.people, jots: jots)
        let error: Error
        do {
            let session = LanguageModelSession(instructions: CallNotesPrompts.factsInstructions)
            let response = try await session.respond(to: prompt, generating: CallPartFacts.self,
                                                     options: retried ? retryOptions : partOptions)
            if retried { log("summary: part \(name) retry ok") }
            reading.answered += 1
            reading.coverage.written()
            return reading.ledger.add(response.content.draft, shown: chunk.ids)
        } catch let failure {
            error = failure
        }
        reading.lastError = error
        let failure = Self.failure(error)
        let halves = chunk.halved()
        let step = Task.isCancelled
            ? .giveUp
            : ladder.next(after: failure, splits: splits, retried: retried, canHalve: halves.count > 1)
        switch step {
        case .again:
            log("summary: part \(name) failed (\(kind(of: error))), trying again")
            return await read(chunk, named: name, jots: jots, part: part, of: count, language: language,
                              splits: splits, retried: true, ladder: &ladder, reading: &reading, log: log)
        case .halve:
            log(failure == .tooLong ? "summary: part \(name) too long, halved"
                                    : "summary: part \(name) halved after \(kind(of: error))")
            var tally = MeetingLedger.Tally()
            let halfJots = CallNotesPrompts.jots(jots, for: halves)
            for (index, half) in halves.enumerated() {
                let more = await read(half, named: name + String(UnicodeScalar(UInt8(97 + index % 26))),
                                      jots: halfJots[index], part: part, of: count, language: language,
                                      splits: splits + 1, ladder: &ladder, reading: &reading, log: log)
                tally.kept += more.kept
                tally.dropped += more.dropped
            }
            return tally
        case .plainText:
            return await plainText(chunk, named: name, prompt: prompt, reading: &reading, log: log)
        case .giveUp:
            log("summary: part \(name) failed (\(kind(of: error))), left unwritten")
            reading.coverage.failed(from: chunk.start, to: chunk.end)
            return MeetingLedger.Tally()
        }
    }

    /// The last try for a piece: the same question, answered in plain
    /// labelled lines (`CallNotesPlainText`) under the guardrails Apple
    /// offers for summarising text, which let through talk the form's
    /// strict ones refuse. The transcript is still only data to take notes
    /// from, and every line read back goes through the same checks.
    private static func plainText(_ chunk: TranscriptChunk, named name: String, prompt: String,
                                  reading: inout Reading, log: (String) -> Void) async -> MeetingLedger.Tally {
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                instructions: CallNotesPlainText.instructions)
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: plainTextAnswerTokens))
            let draft = CallNotesPlainText.read(response.content)
            if CallNotesPlainText.answers(draft, shown: chunk.ids) {
                let tally = reading.ledger.add(draft, shown: chunk.ids)
                reading.answered += 1
                reading.coverage.written()
                log("summary: part \(name) plain-text fallback kept \(tally.kept)")
                return tally
            }
            log("summary: part \(name) plain-text fallback gave no notes, left unwritten")
        } catch {
            reading.lastError = error
            log("summary: part \(name) plain-text fallback failed (\(kind(of: error))), left unwritten")
        }
        reading.coverage.failed(from: chunk.start, to: chunk.end)
        return MeetingLedger.Tally()
    }

    /// The second look (`CallNotesChecks`), a fresh session per question,
    /// each about only the few lines the line of notes comes from. A to-do
    /// gets one first: is it to be done after the meeting at all. An owner
    /// gets two short questions: who took the to-do on, and, only if that
    /// names the owner, whether they took it on or only said it needs
    /// doing. A decision gets one: was it chosen here, or is it an opinion,
    /// how things are, or an idea. An open question gets one: do the lines
    /// after it answer it. A
    /// question that fails counts as not asked, which each side settles
    /// safely: no owner, still open.
    private static func secondLook(_ ledger: inout MeetingLedger, log: (String) -> Void) async {
        let started = Date()
        var asked = 0
        var failed = 0
        var failure: String?
        func ask(_ prompt: String, rules: String) async -> String? {
            asked += 1
            do {
                let session = LanguageModelSession(instructions: rules)
                return try await session.respond(
                    to: prompt,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: checkAnswerTokens)).content
            } catch {
                failed += 1
                failure = kind(of: error)
                return nil
            }
        }
        let people = ledger.people
        var todos: [Int: CallNotesChecks.Answer] = [:]
        for check in ledger.todoChecks() where !Task.isCancelled {
            todos[check.index] = await ask(CallNotesChecks.todoPrompt(for: check, people: people),
                                           rules: CallNotesChecks.todoInstructions)
                .map(CallNotesChecks.Answer.init(choice:))
        }
        let tasks = ledger.settleTodos(todos)
        var owners: [Int: CallNotesChecks.Answer] = [:]
        for check in ledger.ownerChecks() where !Task.isCancelled {
            guard let reply = await ask(CallNotesChecks.whoPrompt(for: check, people: people),
                                        rules: CallNotesChecks.whoInstructions) else { continue }
            let who = CallNotesChecks.Answer(reply: reply, naming: check.owner, among: people)
            guard who == .yes else {
                owners[check.index] = who
                continue
            }
            owners[check.index] = await ask(CallNotesChecks.takenOnPrompt(for: check, people: people),
                                            rules: CallNotesChecks.takenOnInstructions)
                .map(CallNotesChecks.Answer.init(choice:))
        }
        var decisions: [Int: CallNotesChecks.Answer] = [:]
        for check in ledger.decisionChecks() where !Task.isCancelled {
            decisions[check.index] = await ask(CallNotesChecks.decisionPrompt(for: check, people: people),
                                               rules: CallNotesChecks.decisionInstructions)
                .map(CallNotesChecks.Answer.init(firstOf:))
        }
        let chosen = ledger.settleDecisions(decisions)
        var questions: [Int: CallNotesChecks.Answer] = [:]
        for check in ledger.questionChecks() where !Task.isCancelled {
            questions[check.index] = await ask(CallNotesChecks.prompt(for: check),
                                               rules: CallNotesChecks.questionInstructions)
                .map(CallNotesChecks.Answer.init(reply:))
        }
        let owned = ledger.settleOwners(owners)
        let open = ledger.settleQuestions(questions)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        log("summary: second look: to-dos kept \(tasks.yes), dropped \(tasks.no), not asked \(tasks.unasked); "
            + "owners kept \(owned.yes), taken off \(owned.no), not asked \(owned.unasked); "
            + "decisions kept \(chosen.yes), dropped \(chosen.no), not asked \(chosen.unasked); "
            + "questions answered \(open.yes), open \(open.no), not asked \(open.unasked); "
            + "\(asked) asked, \(failed) failed\(failure.map { " (\($0))" } ?? "") in \(seconds)s")
    }

    /// The summary and key points, from the checked lines alone. The lines
    /// without them when this step fails.
    private static func wrapUp(_ ledger: MeetingLedger, language: String?,
                               log: (String) -> Void) async -> MeetingNotes {
        let list = ledger.factList()
        guard !list.items.isEmpty, !Task.isCancelled else {
            log("summary: final step skipped, nothing kept")
            return ledger.notes()
        }
        do {
            let session = LanguageModelSession(instructions: CallNotesPrompts.wrapUpInstructions)
            let response = try await session.respond(
                to: CallNotesPrompts.wrapUp(list, language: language, inPerson: ledger.people.inPerson,
                                            invited: ledger.people.others),
                generating: CallWrapUp.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: wrapUpAnswerTokens))
            let offered = response.content.keyPoints.map { MeetingDraft.Fact(text: $0.text, sources: $0.sources) }
            let keyPoints = ledger.keyPoints(offered, from: list)
            var notes = ledger.notes(summary: response.content.summary, keyPoints: keyPoints.isEmpty ? nil : keyPoints)
            notes.title = response.content.title
            log("summary: final step ok, \(keyPoints.count) of \(offered.count) key point(s) kept"
                + (notes.title == nil ? ", no title" : ", titled"))
            return notes
        } catch {
            log("summary: final step failed (\(kind(of: error))), saved without a summary")
            return ledger.notes()
        }
    }

    /// Which rung of the ladder an error calls for.
    private static func failure(_ error: Error) -> CallNotesLadder.Failure {
        guard let error = error as? LanguageModelSession.GenerationError else { return .garbled }
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .refused
        case .unsupportedLanguageOrLocale: return .language
        default: return .garbled
        }
    }

    /// The error's kind, for the log. Never its text: that can quote what
    /// the model wrote, and so the call.
    private static func kind(of error: Error) -> String {
        guard let error = error as? LanguageModelSession.GenerationError else { return "other" }
        switch error {
        case .exceededContextWindowSize: return "too long"
        case .guardrailViolation: return "guardrail"
        case .refusal: return "refusal"
        case .unsupportedLanguageOrLocale: return "language"
        case .decodingFailure: return "decoding"
        case .rateLimited: return "rate limited"
        case .assetsUnavailable: return "assets unavailable"
        default: return "generation"
        }
    }

    /// Why there are no notes, in words for the page. Not the error's own
    /// text either: the page reason is also logged, and the text of a
    /// garbled answer's error can quote the answer.
    private static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale:
                return "Apple's model doesn't write in this call's language yet."
            case .guardrailViolation, .refusal:
                return "Apple's model declined to summarise this call."
            case .exceededContextWindowSize:
                return "the call was too long for the model to read."
            default:
                break
            }
        }
        return "the model couldn't write them."
    }
}
