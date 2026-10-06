import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The dead air between "Continue to payment" and a working app.
///
/// The property that matters is that **closing the window cancels nothing**. A
/// purchase abandoned by the app while the browser is still open is a payment
/// that lands with nowhere to go, and the person is left holding a receipt for
/// software that still says trial.
@MainActor
final class PurchaseFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testItStartsIdle() {
        let flow = PurchaseFlow()
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertFalse(flow.isWaiting)
    }

    func testBeginningRemembersWhichPlanTheyLeftToBuy() {
        let flow = PurchaseFlow()
        flow.begin(plan: .monthly, now: t0)
        XCTAssertEqual(flow.stage, .waiting(since: t0))
        XCTAssertEqual(flow.plan, .monthly)
        XCTAssertTrue(flow.isWaiting)
    }

    /// THE one. Only finishing or an explicit "Not now" stops the listening —
    /// and neither of those is the window closing.
    func testOnlySuccessOrCancelStopsTheWaiting() {
        let succeeded = PurchaseFlow()
        succeeded.begin(plan: .yearly, now: t0)
        succeeded.succeed()
        XCTAssertEqual(succeeded.stage, .activated)
        XCTAssertFalse(succeeded.isWaiting)

        let cancelled = PurchaseFlow()
        cancelled.begin(plan: .yearly, now: t0)
        cancelled.cancel()
        XCTAssertEqual(cancelled.stage, .idle)
        XCTAssertFalse(cancelled.isWaiting)
    }

    /// A stalled purchase is still a live one: the page may simply still be
    /// open, so the app goes on listening rather than giving up at three
    /// minutes.
    func testStalledIsStillWaiting() {
        let flow = PurchaseFlow()
        flow.begin(plan: .yearly, now: t0)
        flow.stallForTesting()
        XCTAssertEqual(flow.stage, .stalled)
        XCTAssertTrue(flow.isWaiting, "three minutes is a fork, not an ending")
    }

    /// A key can arrive after the fork appears — that is the "paid already"
    /// exit — and it must still land.
    func testAKeyArrivingAfterTheForkStillSucceeds() {
        let flow = PurchaseFlow()
        flow.begin(plan: .yearly, now: t0)
        flow.stallForTesting()
        flow.succeed()
        XCTAssertEqual(flow.stage, .activated)
    }

    /// Three minutes, not thirty seconds: a card form, a 3-D Secure challenge
    /// and a bank app is a normal three minutes, and a fork offered early would
    /// interrupt a purchase that was going fine.
    func testTheStallWindowIsLongEnoughForARealCheckout() {
        XCTAssertGreaterThanOrEqual(PurchaseFlow.stallAfter, 120)
    }

    /// A page that never opened is not something to wait for: the window says
    /// so, remembers the plan for "Try again", and never reaches the fork.
    func testAPageThatDidNotOpenStopsTheWaiting() {
        let flow = PurchaseFlow()
        flow.begin(plan: .monthly, now: t0)
        flow.failToOpen(plan: .monthly)
        XCTAssertEqual(flow.stage, .couldNotOpen)
        XCTAssertEqual(flow.plan, .monthly)
        XCTAssertFalse(flow.isWaiting)
        flow.setStalled()
        XCTAssertEqual(flow.stage, .couldNotOpen, "a stall timer must not turn it into 'still waiting'")
        flow.begin(plan: .yearly, now: t0)
        XCTAssertEqual(flow.stage, .waiting(since: t0), "Try again starts over cleanly")
    }
}

private extension PurchaseFlow {
    /// The timer's effect without its three minutes. Testing the sleep itself
    /// would be testing `Task.sleep`.
    func stallForTesting() {
        guard case .waiting = stage else { return }
        setStalled()
    }
}
