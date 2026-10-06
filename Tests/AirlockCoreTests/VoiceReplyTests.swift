import XCTest
@testable import AirlockCore

/// Classifying what the model came back with, and grading whether it was right.
///
/// Both halves are pure, which is the whole reason `swift run PromptProbe
/// actions` can be a slow opt-in command instead of something `swift test` has
/// to drag a language model into.
final class VoiceReplyTests: XCTestCase {

    // MARK: - Resolving a reply

    func testEmptyActionIsAnAnswer() {
        XCTAssertEqual(VoiceReply.resolve(action: "", arguments: [], answer: " Paris. "),
                       .answer("Paris."))
    }

    /// A model asked for an empty string writes the most reasonable thing a
    /// person would write instead. Every one of these was observed as more
    /// plausible to it than a blank.
    func testWordsMeaningNoActionAreAnswers() {
        for refusal in ["none", "None", "no", "null", "N/A", "nothing", "unknown", "  "] {
            XCTAssertEqual(VoiceReply.resolve(action: refusal, arguments: [], answer: "Paris."),
                           .answer("Paris."), "\(refusal) should not name an action")
        }
    }

    /// A hallucinated action must not become a dead end where the user gets
    /// neither a card nor an answer.
    func testUnknownActionFallsBackToTheProse() {
        XCTAssertEqual(
            VoiceReply.resolve(action: "Voice.SendEmail",
                               arguments: [(name: "to", value: "a@b.c")],
                               answer: "I can't send email."),
            .answer("I can't send email."))
    }

    func testKnownActionWinsOverAccompanyingProse() {
        // Small models fill in every field they are given. The action is the one
        // that was asked for by name, so it takes precedence.
        XCTAssertEqual(
            VoiceReply.resolve(action: "audiooutput",
                               arguments: [(name: "Device", value: "AirPods Pro")],
                               answer: "Sure, switching now."),
            .action(name: "Voice.AudioOutput", arguments: ["device": "AirPods Pro"]))
    }

    func testArgumentKeysAreLoweredAndValuesAreNot() {
        let reply = VoiceReply.resolve(action: "Voice.AudioOutput",
                                       arguments: [(name: " DEVICE ", value: " AirPods Pro ")],
                                       answer: "")
        XCTAssertEqual(reply, .action(name: "Voice.AudioOutput",
                                      arguments: ["device": "AirPods Pro"]))
    }

    func testBlankArgumentsAreDroppedRatherThanCarried() {
        // An action treats a present-but-blank field as absent and a
        // present-and-garbled one as a hard stop, so the difference matters.
        let reply = VoiceReply.resolve(
            action: "Voice.AudioOutput",
            arguments: [(name: "device", value: "AirPods Pro"), (name: "", value: "x"),
                        (name: "note", value: "   ")],
            answer: "")
        XCTAssertEqual(reply, .action(name: "Voice.AudioOutput",
                                      arguments: ["device": "AirPods Pro"]))
    }

    /// An action outside the offering must fall through to being answered — the
    /// same fate as a name that does not exist at all. Stated against an
    /// explicit offering, so it keeps meaning something when the registered set
    /// changes.
    func testAnActionOutsideTheOfferingIsNotAReply() {
        XCTAssertEqual(
            VoiceReply.resolve(action: "Voice.Agent",
                               arguments: [(name: "prompt", value: "run the tests")],
                               answer: "I'd need Claude Code for that.",
                               offering: [VoiceAudioOutputAction.self]),
            .answer("I'd need Claude Code for that."))
    }

    func testRepeatedArgumentKeepsTheFirstValue() {
        let reply = VoiceReply.resolve(
            action: "Voice.AudioOutput",
            arguments: [(name: "device", value: "AirPods Pro"),
                        (name: "device", value: "Kitchen TV")],
            answer: "")
        XCTAssertEqual(reply, .action(name: "Voice.AudioOutput",
                                      arguments: ["device": "AirPods Pro"]))
    }

    // MARK: - The composed prompt

    func testComposedPromptKeepsTheAnsweringInstructionsAndListsWhatIsRegistered() {
        let prompt = VoicePrompt.instructions()
        XCTAssertTrue(prompt.hasPrefix(AssistantPrompt.defaultInstructions),
                      "the user's answering instructions must survive verbatim")
        for action in VoiceActionCatalog.registered {
            XCTAssertTrue(prompt.contains(action.toolName), "\(action.toolName) missing")
        }
    }

    func testComposedPromptFollowsAnEditedBase() {
        // The instructions are editable in Settings; a hand-written second copy
        // of the action list would drift the moment one is added.
        let prompt = VoicePrompt.instructions(answering: "Answer in Catalan.")
        XCTAssertTrue(prompt.hasPrefix("Answer in Catalan."))
        XCTAssertTrue(prompt.contains("Voice.AudioOutput"))
    }

    /// The classifier prompt is what actually ships, so the same rule applies to
    /// it — and it must NOT carry the answering instructions, or it inherits the
    /// job it exists to be separate from.
    func testClassifierPromptListsWhatIsRegisteredAndNothingElse() {
        let prompt = VoicePrompt.classifierInstructions()
        XCTAssertTrue(prompt.contains("Voice.AudioOutput"))
        XCTAssertFalse(prompt.contains(AssistantPrompt.defaultInstructions))
        for action in VoiceActionCatalog.all
        where !VoiceActionCatalog.registered.contains(where: { $0.toolName == action.toolName }) {
            XCTAssertFalse(prompt.contains(action.toolName),
                           "\(action.toolName) is offered but cannot be performed")
        }
    }

    // MARK: - Grading

    private func actionCase(_ tool: String?, _ subject: String?,
                            mustContain: [String] = []) -> ActionEvaluation.Case {
        ActionEvaluation.Case("spoken", tool, subject, "test", mustContain: mustContain)
    }

    /// `offering: .all` on purpose: these cases exercise the conformers and
    /// the rubric, not which of them this build registers. Registration is
    /// pinned separately in `VoiceCatalogTests`.
    private func propose(_ name: String, _ arguments: [String: String]) -> ActionProposal? {
        VoiceActionCatalog.propose(actionNamed: name, arguments: arguments,
                                   in: ActionEvaluation.context,
                                   offering: VoiceActionCatalog.all)
    }

    func testGradingAHit() {
        let proposal = propose("Voice.AudioOutput", ["device": "airpods"])
        XCTAssertEqual(
            ActionEvaluation.grade(actionCase("Voice.AudioOutput", "AirPods Pro"),
                                   reply: .action(name: "Voice.AudioOutput", arguments: [:]),
                                   proposal: proposal),
            .ok)
    }

    /// The safety case: a question that becomes an action is hard, and failing
    /// to act on an instruction is not.
    func testActingOnAQuestionIsHardAndAnsweringInsteadIsNot() {
        let acted = ActionEvaluation.grade(
            actionCase(nil, nil),
            reply: .action(name: "Voice.AudioOutput", arguments: [:]),
            proposal: propose("Voice.AudioOutput", ["device": "airpods"]))
        XCTAssertEqual(acted, .actedInstead("Voice.AudioOutput"))
        XCTAssertTrue(acted.isHard)

        let missed = ActionEvaluation.grade(actionCase("Voice.AudioOutput", "AirPods Pro"),
                                            reply: .answer("Sure."), proposal: nil)
        XCTAssertEqual(missed, .answeredInstead)
        XCTAssertFalse(missed.isHard)
    }

    /// Naming an action that resolves to nothing shows no card, which is exactly
    /// what a must-answer case requires.
    func testAnUnresolvableActionSatisfiesAMustAnswerCase() {
        XCTAssertEqual(
            ActionEvaluation.grade(actionCase(nil, nil),
                                   reply: .action(name: "Voice.AudioOutput", arguments: [:]),
                                   proposal: nil),
            .ok)
    }

    func testWrongActionAndWrongSubjectAreDistinguished() {
        XCTAssertEqual(
            ActionEvaluation.grade(actionCase("Voice.Clipboard", "Figma"),
                                   reply: .action(name: "Voice.AudioOutput", arguments: [:]),
                                   proposal: propose("Voice.AudioOutput", ["device": "airpods"])),
            .wrongAction("Voice.AudioOutput"))

        XCTAssertEqual(
            ActionEvaluation.grade(actionCase("Voice.AudioOutput", "AirPods Pro"),
                                   reply: .action(name: "Voice.AudioOutput", arguments: [:]),
                                   proposal: propose("Voice.AudioOutput", ["device": "kitchen"])),
            .wrongSubject("Kitchen TV"))
    }

    func testLostArgumentsAreCaught() {
        // Right action, right session, but the instruction never reached the card.
        let verdict = ActionEvaluation.grade(
            actionCase("Voice.Agent", "airlock", mustContain: ["commit"]),
            reply: .action(name: "Voice.Agent", arguments: [:]),
            proposal: propose("Voice.Agent", ["prompt": "run the tests"]))
        XCTAssertEqual(verdict, .lostArguments("\"commit\""))
    }

    func testUnresolvedIsDistinctFromAnswering() {
        XCTAssertEqual(
            ActionEvaluation.grade(actionCase("Voice.AudioOutput", "AirPods Pro"),
                                   reply: .action(name: "Voice.AudioOutput", arguments: [:]),
                                   proposal: nil),
            .unresolved)
    }

    // MARK: - The case set itself

    func testEveryExpectedCaseIsActuallyReachableInTheFixture() {
        // A case expecting a subject the sample context cannot produce would fail
        // forever and be blamed on the model.
        for testCase in ActionEvaluation.cases {
            guard let tool = testCase.toolName, let subject = testCase.subject else { continue }
            XCTAssertNotNil(VoiceActionCatalog.action(named: tool),
                            "\(tool) is not in the catalogue")
            let reachable: Bool
            switch tool {
            case "Voice.AudioOutput":
                reachable = ActionEvaluation.context.audioOutputs.contains { $0.name == subject }
            case "Voice.Clipboard":
                reachable = ActionEvaluation.context.clipboard.contains { $0.sourceAppName == subject }
            case "Voice.Agent":
                reachable = ActionEvaluation.context.agentSessions.contains { $0.label == subject }
            case "Voice.Shortcut":
                reachable = ActionEvaluation.context.shortcuts.contains(subject)
            case "Voice.Volume":
                reachable = subject.hasSuffix("%")
            case "Voice.Open":
                reachable = ActionEvaluation.context.apps.contains { $0.name == subject }
                    || ActionEvaluation.context.sites.contains { $0.phrase == subject }
            default:
                // Not a fallthrough to "fine": a new action whose cases nothing
                // here can validate is exactly what this test is for, and
                // `default` staying false is what makes adding one fail loudly.
                reachable = false
            }
            XCTAssertTrue(reachable, "\(subject) does not exist in the sample context")
        }
    }

    func testTheCaseSetCoversBothDirections() {
        let mustAct = ActionEvaluation.cases.filter { $0.toolName != nil }
        let mustAnswer = ActionEvaluation.cases.filter { $0.toolName == nil }
        XCTAssertFalse(mustAct.isEmpty)
        // Without these the run measures eagerness and calls it accuracy.
        XCTAssertGreaterThanOrEqual(mustAnswer.count, 3,
                                    "the must-not-act half is the safety case")
    }
}
