import XCTest
@testable import AirlockCore

final class HoverArbiterTests: XCTestCase {
    private let origin = CGPoint(x: 100, y: 100)
    private func far(_ from: CGPoint) -> CGPoint { CGPoint(x: from.x + 40, y: from.y + 40) }
    private func jitter(_ from: CGPoint) -> CGPoint { CGPoint(x: from.x + 1, y: from.y - 1) }

    func testEnteringAndLeavingFireOnce() {
        var arbiter = HoverArbiter()
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: origin), .entered)
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: origin), .unchanged,
                       "still hovering is not a new entry")
        XCTAssertTrue(arbiter.isHovering)

        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: far(origin)), .left)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: far(origin)), .unchanged)
        XCTAssertFalse(arbiter.isHovering)
    }

    // MARK: - Two regions, one pointer

    /// The catcher owns the cutout and the panel owns everything below it.
    /// Crossing between them is not leaving the notch.
    func testCrossingFromTheCatcherToThePanelIsNotAnExit() {
        var arbiter = HoverArbiter()
        XCTAssertEqual(arbiter.update(.catcher, hovering: true, pointer: origin), .entered)

        let inside = CGPoint(x: origin.x + 30, y: origin.y + 30)
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: inside), .unchanged)
        XCTAssertEqual(arbiter.update(.catcher, hovering: false, pointer: inside), .unchanged,
                       "the panel still has it")
        XCTAssertTrue(arbiter.isHovering)

        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: far(inside)), .left,
                       "only now has the pointer actually gone")
    }

    func testTheLastSourceToLetGoIsTheOneThatEnds() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.update(.catcher, hovering: true, pointer: origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: far(origin)), .unchanged)
        XCTAssertEqual(arbiter.update(.catcher, hovering: false, pointer: far(origin)), .left)
    }

    // MARK: - Exits the user did not perform

    /// Filtering the clipboard to one row shrinks the panel. If the pointer was
    /// over the part that vanished, `.onHover` reports an exit identical to
    /// walking away — and the panel closed itself on the keystroke that
    /// finished the search.
    func testAnExitWithAStationaryPointerIsTheViewMovingNotThePerson() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: origin), .unchanged)
        XCTAssertTrue(arbiter.isHovering, "as far as this is concerned, it never left")
    }

    func testJitterIsNotMovement() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: jitter(origin)), .unchanged)
    }

    /// THE reason the spurious exit does not update the acted-on state: a real
    /// exit afterwards has to still work. Swallowing one and then going deaf
    /// would leave the panel pinned open forever.
    func testARealExitAfterASpuriousOneStillDismisses() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: origin), .unchanged)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: far(origin)), .left,
                       "the pointer has now moved away for real")
    }

    /// And the other recovery: the view comes back under a pointer that never
    /// moved, so nothing should have happened at all.
    func testAViewReturningUnderAStillPointerChangesNothing() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.update(.panel, hovering: false, pointer: origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: origin), .unchanged)
        XCTAssertTrue(arbiter.isHovering)
    }

    // MARK: - Exits the user DID cause, by asking the panel to go away

    /// The tray drop, exactly: the file lands, the pointer stays where it let
    /// go, and 1.5s later the panel collapses on its own timer. The exit that
    /// follows is stationary and therefore indistinguishable from a content
    /// resize — so it was swallowed, and the arbiter went on believing the
    /// pointer was on a panel no longer under it. The next hover-in then read as
    /// a duplicate and the notch stayed shut until you left and came back.
    func testADeliberateCollapseMakesTheNextEntryLand() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)

        arbiter.forgetAnchor() // the controller is collapsing the panel
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: origin), .left,
                       "the panel really did go away, stationary pointer or not")
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: far(origin)), .entered,
                       "one hover in, and it opens")
    }

    /// And the filter it must not take with it: a resize nobody asked for is
    /// still not an exit.
    func testForgettingTheAnchorDoesNotDisarmTheFilterForever() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        arbiter.forgetAnchor()
        _ = arbiter.update(.panel, hovering: false, pointer: origin)

        let entry = far(origin)
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: entry), .entered)
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: entry), .unchanged,
                       "a fresh anchor, and the shrinking-view filter is back")
    }

    // MARK: - Entries the pointer never made

    /// Straight from the trace. The catcher rebuilds its tracking area whenever
    /// its window resizes and reports an arrival, then withdraws it in the same
    /// instant — once while the pointer was sitting on another display:
    ///
    ///     450.70  hover catcher hovering=true  → entered   at (1690, -59)
    ///     450.70  hover catcher hovering=false → unchanged at (1690, -59)
    ///     451.02  apply … peek=true … → expanded (was compact)
    ///
    /// The entry armed the peek, the withdrawal was stationary and so swallowed,
    /// and the island opened over nothing 300ms later. Nothing here can tell the
    /// entry was bogus — but the sources stop claiming the pointer, and that is
    /// what the dwell timer must ask before it fires.
    func testAWithdrawnEntryLeavesNoSourceClaimingThePointer() {
        var arbiter = HoverArbiter()
        XCTAssertEqual(arbiter.update(.catcher, hovering: true, pointer: origin), .entered)
        XCTAssertTrue(arbiter.isReported)

        XCTAssertEqual(arbiter.update(.catcher, hovering: false, pointer: origin), .unchanged)
        XCTAssertFalse(arbiter.isReported, "no source claims it any more")
        XCTAssertTrue(arbiter.isHovering, "though the swallowed exit left us acting as if")
    }

    /// And the other half of the same event: the swallowed exit left the arbiter
    /// believing the pointer was on the notch, so the next REAL hover-in read as
    /// a duplicate and the panel would not open until you left and came back.
    func testArrivingSomewhereNewAfterASwallowedExitIsARealEntry() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.catcher, hovering: true, pointer: origin)
        _ = arbiter.update(.catcher, hovering: false, pointer: origin) // swallowed

        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: far(origin)), .entered,
                       "a pointer that has moved has genuinely arrived")
    }

    /// The rule it must not swallow with it: a view returning under a pointer
    /// that never moved is still not an arrival.
    func testArrivingWhereItNeverLeftIsStillNotAnEntry() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.update(.panel, hovering: false, pointer: origin) // swallowed
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: origin), .unchanged)
    }

    // MARK: - Stopping, which is not the same as staying

    /// The drive-by. The pointer crosses the notch on its way to the menu bar,
    /// so "still inside when the dwell elapses" is true for the whole crossing —
    /// and the island peeked at someone who never aimed at it. Every sample is
    /// somewhere new, so none of them is a stop.
    func testAPointerStillCrossingHasNotStopped() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.catcher, hovering: true, pointer: origin)
        var point = origin
        for _ in 0 ..< 5 {
            point = CGPoint(x: point.x + 20, y: point.y)
            XCTAssertFalse(arbiter.hasStopped(at: point), "still moving at \(point)")
        }
    }

    /// And the peek this exists to allow: the pointer arrives, comes to rest
    /// somewhere other than where it entered, and stays there.
    func testAPointerThatComesToRestHasStopped() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.catcher, hovering: true, pointer: origin)
        let rest = far(origin)
        XCTAssertFalse(arbiter.hasStopped(at: rest),
                       "one sample is not a stop — there is nothing to compare it against")
        XCTAssertTrue(arbiter.hasStopped(at: rest))
    }

    /// A still hand is not a still pointer, which is why the entry/exit filter
    /// has a tolerance at all. The dwell uses the same one.
    func testJitterIsStillAStop() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.hasStopped(at: origin)
        XCTAssertTrue(arbiter.hasStopped(at: jitter(origin)))
    }

    /// Samples belong to the visit that took them. Carrying one across an exit
    /// would let the previous visit answer the next one's first tick — a peek
    /// 150ms after arriving, from a pointer that had not yet stopped.
    func testEachVisitStartsTheDwellOver() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.hasStopped(at: origin)
        XCTAssertTrue(arbiter.hasStopped(at: origin))

        _ = arbiter.update(.panel, hovering: false, pointer: far(origin))
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        XCTAssertFalse(arbiter.hasStopped(at: origin), "a new visit has nothing to compare against")
    }

    func testResetForgetsTheDwellToo() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.hasStopped(at: origin)
        arbiter.reset()
        XCTAssertFalse(arbiter.hasStopped(at: origin), "nothing survives a reset")
    }

    // MARK: - Housekeeping

    func testTheAnchorIsWhereItEnteredNotWhereItStarted() {
        var arbiter = HoverArbiter()
        let entry = CGPoint(x: 500, y: 20)
        _ = arbiter.update(.panel, hovering: true, pointer: entry)
        // Stationary relative to the ENTRY point, not to the origin.
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: entry), .unchanged)
    }

    /// The recovery `NotchController.forgetHover` depends on. A panel torn down
    /// under a stationary pointer never sends its hover-out, so `reporting`
    /// keeps a source that no longer exists — and `isReported` is what the peek
    /// loop asks before expanding. Without a reset there is nothing that can
    /// ever make it false again.
    func testResetClearsTheSourcesThatNoLongerExist() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        _ = arbiter.update(.catcher, hovering: true, pointer: origin)
        XCTAssertTrue(arbiter.isReported)

        arbiter.reset()
        XCTAssertFalse(arbiter.isReported, "a window that is gone claims nothing")
    }

    func testResetForgetsEverything() {
        var arbiter = HoverArbiter()
        _ = arbiter.update(.panel, hovering: true, pointer: origin)
        arbiter.reset()
        XCTAssertFalse(arbiter.isHovering)
        XCTAssertEqual(arbiter.update(.panel, hovering: true, pointer: origin), .entered,
                       "a fresh entry, not a duplicate")
    }

    /// An out event can arrive with no matching in — and acting on it once
    /// closed the panel the instant it opened.
    func testAnExitThatWasNeverPrecededByAnEntryIsIgnored() {
        var arbiter = HoverArbiter()
        XCTAssertEqual(arbiter.update(.panel, hovering: false, pointer: origin), .unchanged)
        XCTAssertFalse(arbiter.isHovering)
    }
}
