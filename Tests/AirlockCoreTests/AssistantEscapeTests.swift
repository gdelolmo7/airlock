import XCTest
@testable import AirlockCore

/// The Escape ladder, asserted rather than discovered by pressing the key.
///
/// Every one of these states needs a non-activating panel, a live event monitor
/// and — for half of them — a microphone to reach by hand, which is exactly why
/// the decision does not live in the view.
final class AssistantEscapeTests: XCTestCase {

    private func step(pending: Bool = false, text: Bool = false,
                      bar: Bool = false, presenting: Bool = false) -> AssistantEscape.Step {
        AssistantEscape.step(hasPending: pending, barHasText: text,
                             barOpen: bar, isPresenting: presenting)
    }

    /// Walked from the top with everything true, dropping one rung at a time —
    /// the order IS the contract, so it is asserted as a sequence rather than as
    /// five unrelated cases.
    func testTheLadderInOrder() {
        XCTAssertEqual(step(pending: true, text: true, bar: true, presenting: true), .dismissCard)
        XCTAssertEqual(step(text: true, bar: true, presenting: true), .clearTypedText)
        XCTAssertEqual(step(bar: true, presenting: true), .closeBar)
        XCTAssertEqual(step(presenting: true), .dismissAnswer)
        XCTAssertEqual(step(), .pass)
    }

    /// A card is waiting on the user, so it outranks every tidying-up rung —
    /// including a bar with unsent words in it.
    func testAPendingCardOutranksEverything() {
        for text in [true, false] {
            for bar in [true, false] {
                for presenting in [true, false] {
                    XCTAssertEqual(
                        step(pending: true, text: text, bar: bar, presenting: presenting),
                        .dismissCard,
                        "a pending card lost to text=\(text) bar=\(bar) presenting=\(presenting)")
                }
            }
        }
    }

    /// An empty bar closes on the FIRST press. Requiring two to shut a field
    /// with nothing in it reads as the key not working.
    func testAnEmptyBarClosesImmediately() {
        XCTAssertEqual(step(bar: true), .closeBar)
        XCTAssertEqual(step(text: true, bar: true), .clearTypedText)
    }

    /// Text only matters while the bar is actually open — a stale non-empty
    /// buffer behind a closed bar must not swallow an Escape aimed at an answer.
    func testTextBehindAClosedBarIsNotARung() {
        XCTAssertEqual(step(text: true, presenting: true), .dismissAnswer)
        XCTAssertEqual(step(text: true), .pass)
    }

    /// The monitor must hand on anything that is not ours. A monitor that eats
    /// every Escape breaks Escape in every other app.
    func testNothingUpMeansNothingSwallowed() {
        XCTAssertEqual(step(), .pass)
    }
}
