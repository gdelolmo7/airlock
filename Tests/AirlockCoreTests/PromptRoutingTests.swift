import XCTest
@testable import AirlockCore

/// One field, two very different costs — so the expensive one has to be picked.
///
/// The asymmetry is the whole design and is what these pin: a question sent to
/// the ladder costs one click, a task answered by a 3B model wastes the useful
/// route entirely. Anything ambiguous goes to the ladder.
final class PromptRoutingTests: XCTestCase {
    // MARK: - Work

    func testAnImperativeOffersBothRoutesWithTheTerminalOnTop() {
        XCTAssertEqual(PromptRouting.candidates(for: "fix the failing snapshot tests"),
                       [.claudeCode, .answer])
    }

    func testTheTerminalIsAlwaysTheTopRungWhenOffered() {
        for phrase in ["rebase onto main", "add a test for the reducer",
                       "refactor AppModel", "run the linter"] {
            XCTAssertEqual(PromptRouting.candidates(for: phrase).first, .claudeCode,
                           "\(phrase) is work, and Return should take it there")
        }
    }

    /// An interrogative buried mid-sentence is a noun. Only the opener counts.
    func testAQuestionWordInsideAnInstructionDoesNotMakeItAQuestion() {
        XCTAssertEqual(PromptRouting.candidates(for: "fix how the parser handles tabs"),
                       [.claudeCode, .answer])
    }

    // MARK: - Questions

    func testAQuestionOffersNoLadder() {
        for phrase in ["how much protein is in 200g of chicken thigh?",
                       "what's left on the reducer branch",
                       "why does the second launch fail",
                       "is the branch behind main"] {
            XCTAssertTrue(PromptRouting.candidates(for: phrase).isEmpty,
                          "\(phrase) has one sensible destination")
        }
    }

    /// A question mark settles it whatever the phrase opens with.
    func testATrailingQuestionMarkIsEnough() {
        XCTAssertTrue(PromptRouting.candidates(for: "ship the reducer fix?").isEmpty)
    }

    func testEmptyIsNotALadder() {
        XCTAssertTrue(PromptRouting.candidates(for: "   ").isEmpty)
    }

    // MARK: - The asymmetry

    /// "can you fix the tests" is a request wearing a question's clothes. It
    /// gets the ladder deliberately — the cost of being wrong the other way is
    /// a useful route that never appears.
    func testARequestPhrasedPolitelyStillGetsTheLadder() {
        XCTAssertEqual(PromptRouting.candidates(for: "can you fix the failing tests"),
                       [.claudeCode, .answer])
    }

    /// Never a single rung: a one-item list is a confirmation dialog.
    func testALadderIsNeverOneRung() {
        for phrase in ["fix the tests", "what is this", "deploy", "how are you"] {
            let candidates = PromptRouting.candidates(for: phrase)
            XCTAssertNotEqual(candidates.count, 1, "\(phrase) produced a one-rung ladder")
        }
    }

    func testLeadingWhitespaceAndCaseDoNotChangeTheAnswer() {
        XCTAssertTrue(PromptRouting.candidates(for: "   WHAT is left on the branch").isEmpty)
        XCTAssertEqual(PromptRouting.candidates(for: "  Fix The Tests"), [.claudeCode, .answer])
    }
}
