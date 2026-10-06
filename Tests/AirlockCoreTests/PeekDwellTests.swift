import XCTest
@testable import AirlockCore

final class PeekDwellTests: XCTestCase {
    /// Everything holding, pointer settled.
    private func step(tick: Int = 1,
                      suppressed: Bool = false,
                      presentation: IslandPresentation? = .compact,
                      pointerReported: Bool = true,
                      pointerStopped: Bool = true) -> PeekDwell.Step {
        PeekDwell.step(tick: tick,
                       suppressed: suppressed,
                       presentation: presentation,
                       pointerReported: pointerReported,
                       pointerStopped: pointerStopped)
    }

    // MARK: - The ordinary shape of a visit

    func testAPointerThatHasSettledGetsItsPeek() {
        XCTAssertEqual(step(), .peek)
    }

    func testAPointerStillMovingIsSampledAgain() {
        XCTAssertEqual(step(pointerStopped: false), .sample)
    }

    // MARK: - Every precondition is re-checked, not trusted from arm time

    /// The bug this type exists for. `hoverSuppressed` and the applied
    /// presentation were read once, when the task was armed; a collapse under
    /// the cursor or the panel disappearing mid-dwell left the loop peeking
    /// anyway.
    func testACollapseUnderTheCursorMidDwellAbandons() {
        XCTAssertEqual(step(tick: 12, suppressed: true), .abandon)
    }

    func testThePanelGoingAwayMidDwellAbandons() {
        XCTAssertEqual(step(tick: 12, presentation: .hidden), .abandon)
        XCTAssertEqual(step(tick: 12, presentation: nil), .abandon,
                       "nothing on screen yet is not a peek either")
    }

    func testAnAlreadyExpandedPanelIsNothingToPeekAt() {
        XCTAssertEqual(step(presentation: .expanded), .abandon)
    }

    func testAPointerNoSourceClaimsAnyMoreAbandons() {
        XCTAssertEqual(step(pointerReported: false), .abandon)
    }

    // MARK: - The bound

    /// Termination must not depend solely on a report from somewhere else: the
    /// failure being guarded against is exactly one of those reports being
    /// wrong. A lost hover-out leaves `pointerReported` true forever.
    func testTheLoopEndsOnItsOwnEvenWithEveryConditionStillHolding() {
        XCTAssertEqual(step(tick: PeekDwell.maxTicks - 1), .peek)
        XCTAssertEqual(step(tick: PeekDwell.maxTicks), .abandon)
        XCTAssertEqual(step(tick: PeekDwell.maxTicks + 500), .abandon)
    }

    func testTheBoundIsLongEnoughToBeAboutSettlingAndShortEnoughToBeOver() {
        let seconds = Double(PeekDwell.maxTicks)
            * Double(PeekDwell.tickNanoseconds) / 1_000_000_000
        XCTAssertGreaterThan(seconds, 2, "two samples answers 'has it stopped'; leave slack")
        XCTAssertLessThan(seconds, 15, "a wedged loop must not outlive the gesture that armed it")
    }

    func testTheEarliestPeekIsStillTheDocumentedDwell() {
        // Two samples at 150ms is 300ms. `hasStopped` is false until there are
        // two of them, so tick 0 can only ever be `.sample`.
        XCTAssertEqual(PeekDwell.tickNanoseconds, 150_000_000)
        XCTAssertEqual(step(tick: 0, pointerStopped: false), .sample)
    }

    // MARK: - The invariant

    /// **This path may only ever REFUSE a peek; it must never be able to CAUSE
    /// an expansion.**
    ///
    /// Stated as a sweep rather than a sentence: over every combination of
    /// inputs, `.peek` implies the whole precondition set. A condition dropped
    /// from `step` — which is how this broke the first time — fails here even if
    /// nobody thinks to write the case by hand.
    func testPeekingImpliesEveryPreconditionHeld() {
        for tick in [0, 1, 7, PeekDwell.maxTicks - 1, PeekDwell.maxTicks, PeekDwell.maxTicks + 1] {
            for suppressed in [false, true] {
                for presentation in [IslandPresentation?.none, .hidden, .compact, .expanded] {
                    for reported in [false, true] {
                        for stopped in [false, true] {
                            let result = PeekDwell.step(tick: tick,
                                                        suppressed: suppressed,
                                                        presentation: presentation,
                                                        pointerReported: reported,
                                                        pointerStopped: stopped)
                            guard result == .peek else { continue }
                            XCTAssertLessThan(tick, PeekDwell.maxTicks)
                            XCTAssertFalse(suppressed)
                            XCTAssertEqual(presentation, .compact)
                            XCTAssertTrue(reported)
                            XCTAssertTrue(stopped)
                        }
                    }
                }
            }
        }
    }

    /// The other half of the same invariant: weakening any single input can only
    /// move the answer away from `.peek`, never towards it.
    func testNoSingleInputTurningAgainstUsCanProduceAPeek() {
        XCTAssertEqual(step(), .peek, "the baseline is the only peeking combination")
        XCTAssertNotEqual(step(suppressed: true), .peek)
        XCTAssertNotEqual(step(presentation: .hidden), .peek)
        XCTAssertNotEqual(step(presentation: .expanded), .peek)
        XCTAssertNotEqual(step(presentation: nil), .peek)
        XCTAssertNotEqual(step(pointerReported: false), .peek)
        XCTAssertNotEqual(step(pointerStopped: false), .peek)
        XCTAssertNotEqual(step(tick: PeekDwell.maxTicks), .peek)
    }
}
