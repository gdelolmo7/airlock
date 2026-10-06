import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The half of the battery widget that the pure tests cannot see: it is now
/// driven by an IOKit run-loop source rather than a ten-second poll, and the C
/// callback that source calls has to be handed `self` as a raw pointer.
///
/// Nothing here can prove a cable was pulled — no test process gets a power
/// event on demand. What it can prove is the part that is a memory bug rather
/// than a behaviour bug: installing the source, doing it twice, and taking it
/// back down are all balanced, so the retained context pointer is never
/// double-released and never left pointing at a freed model.
@MainActor
final class BatteryObservationTests: XCTestCase {

    /// Runs on a laptop and on a desktop alike: `state` is nil where there is no
    /// battery, and that is a legitimate reading, not a failure. What is asserted
    /// is that starting reads the source SYNCHRONOUSLY — the old code waited for
    /// the first timer tick, so the gutter's first paint had nothing in it.
    func testStartingTakesAReadingImmediatelyRatherThanWaitingForATick() {
        let started = BatteryWidgetModel()
        defer { started.stop() }
        started.start()

        let read = BatteryWidgetModel()
        read.refresh()

        // Whatever this machine's answer is — a percentage on a laptop, nil on a
        // desktop — `start()` already has it, with no tick elapsed.
        XCTAssertEqual(started.state, read.state)
    }

    /// `start()` installs a run-loop source and retains `self` for its C context.
    /// A second call must not install a second source or take a second retain —
    /// that is a leak on the way in and an over-release on the way out.
    func testStartingTwiceInstallsOneSourceAndStopsCleanly() {
        let model = BatteryWidgetModel()
        model.start()
        model.start()
        model.stop()
        // Idempotent in both directions: a second stop has nothing left to
        // release, and must not try.
        model.stop()
    }

    /// The model is released while nothing is installed — the state the retained
    /// context pointer exists to make reachable. If `stop()` did not balance the
    /// retain this would simply leak; if it over-released, this crashes.
    func testAStoppedModelCanBeReleased() {
        weak var weakModel: BatteryWidgetModel?
        autoreleasepool {
            let model = BatteryWidgetModel()
            weakModel = model
            model.start()
            model.stop()
        }
        XCTAssertNil(weakModel, "stop() left a retain on the model")
    }

    /// The sentence the gutter's tooltip and accessibility label both use comes
    /// from Core, not from the view. This is the wiring, not the wording —
    /// `BatteryReadingTests` owns the wording.
    func testTheSpokenReadingIsTheCoreOne() {
        let state = BatteryState(percentage: 42, isCharging: false, isCharged: false,
                                 isPluggedIn: false, minutesRemaining: 95)
        XCTAssertEqual(state.spoken,
                       BatteryReading.status(percentage: 42, isCharging: false,
                                             isPluggedIn: false, isCharged: false,
                                             minutesRemaining: 95))
        XCTAssertEqual(state.spoken, "Battery 42%, 1 hour 35 minutes left")
    }
}
