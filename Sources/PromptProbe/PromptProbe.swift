import Foundation
import FoundationModels
import AirlockCore
import AirlockGenerable

/// Scores the assistant's instructions against `PromptEvaluation.cases`.
///
/// A separate executable rather than a test, for two reasons that are the same
/// reason: it needs a language model. That makes it slow (fourteen generations),
/// and it makes it unavailable wherever Apple Intelligence is off — neither of
/// which belongs in `swift test`, which has to stay fast and hermetic. The half
/// that CAN be hermetic, the grading, lives in Core and is tested there.
///
///     swift run PromptProbe                 # score the shipped instructions
///     swift run PromptProbe path/to/alt.txt # score an alternative
///     swift run PromptProbe a.txt b.txt     # compare
///     swift run PromptProbe actions --dry … # the voice-action path, no model
///     swift run PromptProbe intent          # the ask-key sort: rules, then the model
///
/// Exits non-zero on any hard failure — an answer that recites the prompt or
/// states something false — so it can gate a prompt change rather than merely
/// describe one.
///
/// The `actions` subcommand is the one part that needs no model: it runs the
/// pure resolution-and-policy path with arguments supplied by hand, which is
/// what makes Phase 1 of the voice-actions plan inspectable before any UI
/// exists. Model-backed action scoring joins it in Phase 2.
@main
struct PromptProbe {
    static func main() async {
        // Before the availability guard, deliberately: the dry path runs no
        // generation, so refusing it on a Mac with Apple Intelligence off would
        // be refusing to run pure code.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "actions" {
            exit(await VoiceActionProbe.run(Array(arguments.dropFirst())))
        }

        guard case .available = SystemLanguageModel.default.availability else {
            FileHandle.standardError.write(Data(
                "PromptProbe needs Apple Intelligence turned on.\n".utf8))
            exit(2)
        }
        #if AIRLOCK_GUIDE
        // The ask-key sort decides when the guide starts, so it ships with it.
        if arguments.first == "intent" {
            exit(await IntentScoring.run())
        }
        #endif

        let paths = arguments
        var subjects: [(String, String)] = []
        if paths.isEmpty {
            subjects = [("shipped", AssistantPrompt.defaultInstructions)]
        } else {
            for path in paths {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    FileHandle.standardError.write(Data("can't read \(path)\n".utf8))
                    exit(2)
                }
                subjects.append(((path as NSString).lastPathComponent, text))
            }
        }

        var hardFailures = 0
        for (name, instructions) in subjects {
            let card = await score(instructions)
            report(name: name, card: card)
            hardFailures += card.hardFailures
        }
        exit(hardFailures == 0 ? 0 : 1)
    }

    private static func score(_ instructions: String) async -> PromptEvaluation.Scorecard {
        var card = PromptEvaluation.Scorecard()
        for testCase in PromptEvaluation.cases {
            // A fresh session per question. Reusing one would let each answer
            // condition the next, and the app asks each question cold.
            let session = LanguageModelSession(instructions: instructions)
            var answer = ""
            do {
                for try await partial in session.streamResponse(
                    to: testCase.question,
                    options: GenerationOptions(
                        // Matches AssistantService. Without it a difference
                        // between runs is indistinguishable from a difference
                        // between prompts, which invalidated an entire round of
                        // this comparison once already.
                        sampling: .greedy,
                        maximumResponseTokens: AssistantPrompt.maximumResponseTokens)) {
                    answer = partial.content
                }
            } catch {
                answer = "<<threw: \(error.localizedDescription)>>"
            }
            let verdict = PromptEvaluation.grade(testCase, answer: answer,
                                                 instructions: instructions)
            card.verdicts.append((testCase, answer, verdict))
        }
        return card
    }

    private static func report(name: String, card: PromptEvaluation.Scorecard) {
        print("\n═══ \(name)")
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
              + " · echoed \(card.count { $0 == .echoedQuestion })"
              + " · guessed \(card.count { $0 == .guessed })"
              + " · over-refused \(card.count { $0 == .overRefused })"
              + " · avg \(card.averageWords) words")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
