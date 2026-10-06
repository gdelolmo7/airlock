import Foundation
import FoundationModels
import AirlockCore
import AirlockGenerable

/// Phase 2 of the voice-actions plan: does teaching the assistant to *act* cost
/// anything in how it *answers*?
///
///     swift run PromptProbe actions
///
/// Runs two case sets through the composed prompt and prints both, because the
/// decision needs both numbers. Adding actions is only worth doing if the
/// answering score holds — an assistant that gained six commands and lost two
/// answers is a worse assistant, and without the second run that trade is
/// invisible.
///
/// **The comparison is deliberately not like-for-like, and it is the right
/// comparison anyway.** The control is what ships today: free-text generation
/// under the answering-only prompt. The candidate is what Phase 3 would ship:
/// guided generation under the composed prompt. So a difference could come from
/// the schema rather than the wording — and it does not matter which, because
/// they arrive together or not at all.
///
/// Exits non-zero on any HARD failure in either set: a recited or fabricated
/// answer, or a question that turned into an action.
enum ActionScoring {
    /// `classifierOnly` skips configuration A. A is measured, dead, and costs 24
    /// generations to re-confirm; iterating on B should not have to pay for it.
    static func run(classifierOnly: Bool = false) async -> Int32 {
        var costA = 0
        var combinedActions = ActionEvaluation.Scorecard()
        var answering = (card: PromptEvaluation.Scorecard(),
                         acted: [(PromptEvaluation.Case, String)]())
        if !classifierOnly {
            // ── A: one call does both jobs.
            let combined = VoicePrompt.instructions()
            print("\n╔══ A · COMPOSED — one call answers or acts "
                  + "(\(combined.split(whereSeparator: \.isWhitespace).count) words)")
            combinedActions = await scoreActions(combined)
            reportActions(combinedActions)
            answering = await scoreAnswering(combined)
            reportAnswering(answering.card, actedOn: answering.acted)
            costA = combinedActions.hardFailures + answering.card.hardFailures
                + answering.acted.count
        }

        // ── B: a classifying pass in front of the answering path, untouched.
        let classifier = VoicePrompt.classifierInstructions()
        print("\n╔══ B · CLASSIFIER — a first pass that only acts; answering unchanged "
              + "(\(classifier.split(whereSeparator: \.isWhitespace).count) words)")
        let classifierActions = await scoreActions(classifier)
        reportActions(classifierActions)

        // Every answering case is ALSO a held-fire case for B: in this shape the
        // classifier sees each of them first, and anything it claims never
        // reaches the answering path at all.
        let leaks = await scoreHeldFire(classifier)
        print("  ── held fire on the 14 answering questions: "
              + "\(PromptEvaluation.cases.count - leaks.count)/\(PromptEvaluation.cases.count)")
        for (question, what) in leaks { print("  ✗✗ CLAIMED a question: \(question) → \(what)") }
        let costB = classifierActions.hardFailures + leaks.count

        print("\n═══ verdict")
        print("  answering, free text under today's prompt   13/14 ok · 0 hard  (control)")
        if !classifierOnly {
            print("  A composed   acting \(combinedActions.firedCorrectly) fired · "
                  + "answering \(answering.card.passed)/\(answering.card.total) · \(costA) hard")
        }
        print("  B classifier acting \(classifierActions.firedCorrectly) fired · "
              + "answering unchanged by construction · \(costB) hard")
        return costB == 0 ? 0 : 1
    }

    /// Does the classifier claim a plain question? Anything it claims never
    /// reaches the answering path, so each one is a lost answer.
    private static func scoreHeldFire(_ instructions: String) async -> [(String, String)] {
        var leaks: [(String, String)] = []
        for testCase in PromptEvaluation.cases {
            let (reply, note) = await ask(testCase.question, instructions: instructions)
            guard note == nil, case .action(let name, let arguments) = reply else { continue }
            // Only a claim that RESOLVES costs an answer — one that resolves to
            // nothing falls through to answering exactly as it should.
            guard let proposal = VoiceActionCatalog.propose(actionNamed: name,
                                                            arguments: arguments,
                                                            in: ActionEvaluation.context)
            else { continue }
            leaks.append((testCase.question, proposal.summary))
        }
        return leaks
    }

    // MARK: - Acting

    private static func scoreActions(_ instructions: String) async -> ActionEvaluation.Scorecard {
        var card = ActionEvaluation.Scorecard()
        for testCase in ActionEvaluation.cases {
            // A case for an action this build does not register is not a
            // failure, it is out of scope — and scoring it as a miss would bury
            // a real regression under two known absences.
            if let tool = testCase.toolName, VoiceActionCatalog.resolve(name: tool) == nil {
                print("  – \(testCase.spoken)\n      skipped, \(tool) is not registered")
                continue
            }
            let (reply, note) = await ask(testCase.spoken, instructions: instructions)
            let proposal: ActionProposal?
            if case .action(let name, let arguments) = reply {
                proposal = VoiceActionCatalog.propose(actionNamed: name, arguments: arguments,
                                                      in: ActionEvaluation.context)
            } else {
                proposal = nil
            }
            card.verdicts.append((testCase, note ?? describe(reply, proposal: proposal),
                                  ActionEvaluation.grade(testCase, reply: reply,
                                                         proposal: proposal)))
        }
        return card
    }

    private static func reportActions(_ card: ActionEvaluation.Scorecard) {
        print("\n═══ acting")
        for (testCase, observed, verdict) in card.verdicts {
            let mark = verdict == .ok ? "✓" : (verdict.isHard ? "✗✗" : "✗")
            print("  \(mark) \(testCase.spoken)")
            if verdict != .ok { print("      \(verdict.label)  [\(testCase.note)]") }
            print("      → \(observed.prefix(140))")
        }
        print("  ── \(card.passed)/\(card.total) ok"
              + " · fired \(card.firedCorrectly)"
              + " · held fire \(card.heldFire)"
              + " · hard failures \(card.hardFailures)")

        // A question that named an action and was only spared because the
        // argument named nothing real is NOT a hold, and counting it as one
        // flatters the number. It means the classifier decided to act and the
        // resolver caught it — so the same phrase on a Mac that happens to own a
        // device by that name would have produced a card.
        let lucky = card.verdicts.filter { $0.0.toolName == nil && $0.1.contains("Voice.") }
        if !lucky.isEmpty {
            print("  ⚠︎ \(lucky.count) of those holds were saved by resolution, not by judgement:")
            for (testCase, observed, _) in lucky {
                print("      \(testCase.spoken) → \(observed.prefix(90))")
            }
        }
    }

    // MARK: - Answering

    /// The regression half. `acted` is the new failure mode and has no verdict
    /// in `PromptEvaluation` — that rubric predates a prompt that could act —
    /// so it is counted here rather than bent into an existing case.
    private static func scoreAnswering(_ instructions: String) async
        -> (card: PromptEvaluation.Scorecard, acted: [(PromptEvaluation.Case, String)]) {
        var card = PromptEvaluation.Scorecard()
        var acted: [(PromptEvaluation.Case, String)] = []
        for testCase in PromptEvaluation.cases {
            let (reply, note) = await ask(testCase.question, instructions: instructions)
            var answer = note ?? ""
            if note == nil {
                switch reply {
                case .answer(let text):
                    answer = text
                case .action(let name, let arguments):
                    acted.append((testCase, "\(name) \(arguments)"))
                    answer = ""
                }
            }
            card.verdicts.append((testCase, answer,
                                  PromptEvaluation.grade(testCase, answer: answer,
                                                         instructions: instructions)))
        }
        return (card, acted)
    }

    private static func reportAnswering(_ card: PromptEvaluation.Scorecard,
                                        actedOn: [(PromptEvaluation.Case, String)]) {
        print("\n═══ answering, under the composed prompt")
        for (testCase, answer, verdict) in card.verdicts {
            let mark = verdict == .ok ? "✓" : (verdict.isHard ? "✗✗" : "✗")
            print("  \(mark) \(testCase.question)")
            if verdict != .ok { print("      \(verdict.label)  [\(testCase.note)]") }
            print("      → \(oneLine(answer).prefix(140))")
        }
        print("  ── \(card.passed)/\(card.total) ok"
              + " · hard failures \(card.hardFailures)"
              + " · recited \(card.count { if case .recitedPrompt = $0 { return true }; return false })"
              + " · wrong \(card.count { if case .factuallyWrong = $0 { return true }; return false })"
              + " · guessed \(card.count { $0 == .guessed })"
              + " · avg \(card.averageWords) words")
        print("  ── baseline to beat, free text under the answering-only prompt: "
              + "13/14 ok · 0 hard · 0 recited · 0 wrong · 1 guessed · 39 words")
        for (testCase, what) in actedOn {
            print("  ✗✗ ACTED on a question: \(testCase.question) → \(what)")
        }
    }

    // MARK: - The model call

    /// One question, cold. Returns the reply, or a note when nothing usable came
    /// back — a guardrail refusal is a first-class outcome here, not a crash.
    private static func ask(_ spoken: String,
                            instructions: String) async -> (VoiceReply, String?) {
        // A fresh session per case, for the reason `PromptProbe.score` gives:
        // reusing one lets each reply condition the next, and the app asks cold.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: spoken,
                generating: SpokenReply.self,
                options: GenerationOptions(
                    // Matches `AssistantService`, and matches the control run.
                    // Without it a difference between prompts is indistinguishable
                    // from a difference between runs.
                    sampling: .greedy,
                    maximumResponseTokens: VoicePrompt.maximumClassifierTokens))
            return (response.content.reply, nil)
        } catch {
            return (.answer(""), "<<threw: \(error.localizedDescription)>>")
        }
    }

    private static func describe(_ reply: VoiceReply, proposal: ActionProposal?) -> String {
        switch reply {
        case .answer(let text):
            return oneLine(text).isEmpty ? "(no answer, no action)" : oneLine(text)
        case .action(let name, let arguments):
            let bag = arguments.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(name) \(bag)  ⇒  \(proposal?.summary ?? "resolved to nothing")"
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
