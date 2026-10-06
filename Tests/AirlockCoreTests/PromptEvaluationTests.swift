import XCTest
@testable import AirlockCore

/// The grader, tested with no model in sight.
///
/// These matter more than they look. Two rubrics shipped before this one and both
/// flattered the wrong thing — the first graded the shape of an answer while
/// ignoring whether it was true, the second counted a refusal as success without
/// checking it was a sentence, and rated a prompt 14/14 while five of its answers
/// were reciting the prompt back. A grader that is wrong is worse than no grader,
/// because it produces a number people then trust.
final class PromptEvaluationTests: XCTestCase {
    private let instructions = AssistantPrompt.defaultInstructions

    // MARK: - Leak detection

    /// The exact failure that fooled the earlier rubric. An instruction reading
    /// "say you don't have it and suggest Claude Code" invites a small model to
    /// answer in those words.
    func testRecitedInstructionIsCaught() {
        let recited = "I cannot, and that Claude Code can."
        let scripted = "When a question needs one of those, say in one short sentence "
            + "that you cannot, and that Claude Code can. Never guess."
        XCTAssertNotNil(PromptEvaluation.leakedPhrase(answer: recited, instructions: scripted))
    }

    /// A genuine answer that happens to share vocabulary with the instructions —
    /// "Claude Code", "internet", "clock" all appear in them — must not be
    /// mistaken for a quotation.
    func testNaturalAnswerSharingVocabularyIsNotALeak() {
        XCTAssertNil(PromptEvaluation.leakedPhrase(
            answer: "I don't have a clock, so I can't tell you the time in Tokyo. "
                + "Claude Code could.",
            instructions: instructions))
        XCTAssertNil(PromptEvaluation.leakedPhrase(
            answer: "**Paris** is the capital of France.", instructions: instructions))
    }

    /// Six words, not five: five catches ordinary English and would fail every
    /// honest answer.
    func testRunLengthIsTheDifferenceBetweenQuotingAndCoinciding() {
        let source = "Prefer a plain sentence to a list when answering."
        // Exactly five shared words — a coincidence at this length.
        XCTAssertNil(PromptEvaluation.leakedPhrase(
            answer: "Prefer a plain sentence to something else.", instructions: source))
        // Six — a quotation.
        XCTAssertNotNil(PromptEvaluation.leakedPhrase(
            answer: "You should prefer a plain sentence to a list here.",
            instructions: source))
    }

    func testShortAnswersCannotLeak() {
        XCTAssertNil(PromptEvaluation.leakedPhrase(answer: "Paris", instructions: instructions))
        XCTAssertNil(PromptEvaluation.leakedPhrase(answer: "", instructions: instructions))
    }

    // MARK: - Precedence

    /// A recitation that happens to be a valid-looking decline. Checking the
    /// expectation first scored this as a pass, which is how a broken prompt
    /// reached 14/14.
    func testRecitationOutranksASuccessfulDecline() {
        let scripted = "say in one short sentence that you cannot, and that Claude Code can"
        let testCase = PromptEvaluation.Case("what time is it in Tokyo", .decline, "no clock")
        let verdict = PromptEvaluation.grade(testCase,
                                             answer: "I cannot, and that Claude Code can.",
                                             instructions: scripted)
        XCTAssertTrue(verdict.isHard)
        guard case .recitedPrompt = verdict else {
            return XCTFail("expected a recitation, got \(verdict.label)")
        }
    }

    /// Truth outranks shape. The answer below is a well-formed sentence that
    /// answers the question and is wrong.
    func testFabricationOutranksAWellFormedAnswer() {
        let testCase = PromptEvaluation.cases.first {
            $0.question.contains("largest moon")
        }!
        let verdict = PromptEvaluation.grade(
            testCase, answer: "Saturn's moon Titan is the largest moon in the solar system.",
            instructions: instructions)
        XCTAssertTrue(verdict.isHard)
        guard case .factuallyWrong = verdict else {
            return XCTFail("expected a fabrication, got \(verdict.label)")
        }
    }

    // MARK: - The three expectations

    func testDeclineIsSatisfiedByAdmittingTheLimit() {
        let testCase = PromptEvaluation.Case("what's the weather tomorrow", .decline, "no internet")
        XCTAssertEqual(PromptEvaluation.grade(
            testCase, answer: "I don't have internet access, so I can't check that.",
            instructions: instructions), .ok)
        XCTAssertEqual(PromptEvaluation.grade(
            testCase, answer: "Tomorrow will be sunny and 22 degrees.",
            instructions: instructions), .guessed)
    }

    func testAnswerableQuestionRefusedIsAFailure() {
        let testCase = PromptEvaluation.Case("what's a monad", .answer, "definition")
        XCTAssertEqual(PromptEvaluation.grade(
            testCase, answer: "I can't help with that.", instructions: instructions),
            .overRefused)
    }

    func testVagueQuestionHandedBackIsAnEcho() {
        let testCase = PromptEvaluation.Case("Okay, how does this work?", .clarify, "the measured echo")
        XCTAssertEqual(PromptEvaluation.grade(
            testCase, answer: "How does this work?", instructions: instructions),
            .echoedQuestion)
    }

    // MARK: - The case set itself

    /// Every case must be gradeable: an `.answer` case with no `mustContain` is
    /// only checked for shape, which is how a wrong answer slipped through once.
    func testFactualCasesAssertAFact() {
        let factual = PromptEvaluation.cases.filter { $0.expectation == .answer }
        let checked = factual.filter { !$0.mustContain.isEmpty || !$0.mustNotContain.isEmpty }
        XCTAssertGreaterThanOrEqual(checked.count, factual.count / 2,
                                    "most answerable cases should assert something true")
    }

    /// The shipped instructions must not contain a sentence a model could answer
    /// with. This is the property that broke, expressed directly.
    func testShippedInstructionsDoNotDictateAnAnswer() {
        for phrase in ["I cannot", "I can't", "I don't have"] {
            XCTAssertFalse(instructions.contains(phrase),
                           "instructions put a first-person sentence in the model's mouth "
                           + "(\"\(phrase)\") — it will recite it")
        }
    }

    func testCaseSetCoversEveryExpectation() {
        let kinds = Set(PromptEvaluation.cases.map(\.expectation))
        XCTAssertEqual(kinds, [.answer, .decline, .clarify])
    }
}

/// Restating an instruction is as empty as handing a question back.
final class EchoOfAnInstructionTests: XCTestCase {

    /// The reported failure: an instruction repeated back, with a full stop
    /// rather than a question mark, so the "?" test never saw it. It reads as
    /// the app acknowledging something it has not done.
    func testAnInstructionRepeatedBackIsAnEcho() {
        XCTAssertTrue(AssistantPrompt.isEcho(question: "okay decrease the music by 10%",
                                             answer: "Decrease the music by 10%."))
        XCTAssertTrue(AssistantPrompt.isEcho(question: "open spotify",
                                             answer: "Open Spotify."))
    }

    /// The case the "?" test was written for must survive: every word reused,
    /// one added, and a perfectly good answer to something that WAS asked.
    func testAnAnswerBuiltFromTheQuestionsWordsIsStillAnAnswer() {
        XCTAssertFalse(AssistantPrompt.isEcho(question: "is Swift statically typed",
                                              answer: "Yes, Swift is statically typed."))
        XCTAssertFalse(AssistantPrompt.isEcho(question: "what's the capital of France",
                                              answer: "Paris"))
    }

    /// A question handed back is still an echo, whichever shape it arrived in.
    func testAQuestionHandedBackIsStillAnEcho() {
        XCTAssertTrue(AssistantPrompt.isEcho(question: "what is a monad",
                                             answer: "What is a monad?"))
    }

    /// A real answer to an instruction is longer than the instruction, so the
    /// word-count guard lets it through before any of this is reached.
    func testAGenuineReplyToAnInstructionIsNotAnEcho() {
        XCTAssertFalse(AssistantPrompt.isEcho(
            question: "decrease the music by 10%",
            answer: "I can't change the volume, but you can use the keys on your keyboard."))
    }
}
