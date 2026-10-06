import XCTest
@testable import AirlockCore

/// Moving the pointer away from an answer you have read should take it with you.
final class AnswerDismissalTests: XCTestCase {

    private func exit(answer: Bool = true, hovered: Bool = true, card: Bool = false) -> Bool {
        AnswerDismissal.onPointerExit(answerShowing: answer,
                                      hoveredSinceAnswer: hovered,
                                      hasPendingCard: card)
    }

    /// The reported bug: hover on, hover off, and it stayed until Escape.
    func testAnAnswerYouHoveredAndLeftIsDismissed() {
        XCTAssertTrue(exit())
    }

    /// Edge-triggered. An out event can arrive with no matching in — the panel
    /// torn down under a stationary pointer reports one — and acting on that
    /// alone dismissed the answer the instant it appeared.
    func testAnExitWithoutAnEntryIsIgnored() {
        XCTAssertFalse(exit(hovered: false))
    }

    /// A card is a question waiting on the user. Walking away is not an answer,
    /// and dropping it would log `.deferred` with the agent still waiting.
    func testAPendingCardIsNeverDismissedByThePointer() {
        for hovered in [true, false] {
            XCTAssertFalse(exit(hovered: hovered, card: true),
                           "a pending card was dropped by the pointer leaving")
        }
    }

    /// Nothing showing, nothing to dismiss — the exit belongs to some other
    /// claimant on the panel.
    func testNoAnswerMeansNothingToDo() {
        XCTAssertFalse(exit(answer: false))
        XCTAssertFalse(exit(answer: false, hovered: false))
    }
}
