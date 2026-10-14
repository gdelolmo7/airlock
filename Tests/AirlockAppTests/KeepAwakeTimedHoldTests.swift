import XCTest
import IOKit.pwr_mgt
import AirlockCore
@testable import AirlockApp

/// The switch's hold with an end, driven through the model.
///
/// The rules are `KeepAwakeTimer`'s and tested there. What is tested here is
/// the wiring around them: which hold the end releases, what it leaves
/// behind, and what a press does to an end. The assertions are stand-ins
/// (`PowerAssertions`), so nothing here keeps the Mac running it awake.
@MainActor
final class KeepAwakeTimedHoldTests: XCTestCase {
    /// What the stand-in is holding, by the reason each hold was taken for.
    @MainActor private final class Ledger {
        var held: [IOPMAssertionID: String] = [:]
        var taken = 0
        var reasons: [String] { held.values.sorted() }
    }

    private static let switchReason = "Airlock — keep awake"
    private static let agentReason = "Airlock — an agent is working"

    private func makeModel() -> (SystemControlsModel, Ledger) {
        let ledger = Ledger()
        let model = SystemControlsModel(power: PowerAssertions(
            create: { _, reason in
                ledger.taken += 1
                let id = IOPMAssertionID(ledger.taken)
                ledger.held[id] = reason as String
                return (kIOReturnSuccess, id)
            },
            release: { id in
                ledger.held[id] = nil
                return kIOReturnSuccess
            }))
        return (model, ledger)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "keepAwake.untilMinute")
        UserDefaults.standard.removeObject(forKey: "keepAwake.whileAgentsWork.onBattery")
        super.tearDown()
    }

    func testALengthHoldsWithAnEnd() {
        let (model, ledger) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        XCTAssertTrue(model.isAwake)
        XCTAssertEqual(model.awakeUntil, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(ledger.reasons, [Self.switchReason])
    }

    /// One click keeps doing what it always did: whatever `singleClick` says,
    /// and today that is no end at all.
    func testOneClickStartsTheSingleClickChoice() {
        let (model, _) = makeModel()
        model.activate(.awake)
        XCTAssertTrue(model.isAwake)
        XCTAssertEqual(model.awakeUntil == nil, KeepAwakeTimer.singleClick == .untilTurnedOff)
    }

    func testUntilTurnedOffNeverEndsByItself() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.untilTurnedOff, now: now)
        XCTAssertNil(model.awakeUntil)
        XCTAssertFalse(model.endAwakeIfDue(now: now.addingTimeInterval(7 * 24 * 3600)))
        XCTAssertTrue(model.isAwake)
    }

    func testTheEndLetsGoAndLeavesAQuietLine() {
        let (model, ledger) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        XCTAssertFalse(model.endAwakeIfDue(now: now.addingTimeInterval(30 * 60 - 1)))
        XCTAssertTrue(model.isAwake)

        XCTAssertTrue(model.endAwakeIfDue(now: now.addingTimeInterval(30 * 60)))
        XCTAssertFalse(model.isAwake)
        XCTAssertNil(model.awakeUntil)
        XCTAssertEqual(ledger.reasons, [])
        XCTAssertEqual(model.failure, .init(sentence: KeepAwakeTimer.endedMessage, isNote: true))
        // Not the cutoff's notice: the compact island has nothing to flash.
        XCTAssertNil(model.stoppedByCutoffAt)
    }

    /// A Mac that slept through the end lets go on the first check after.
    func testWakingPastTheEndLetsGoAtOnce() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 60), now: now)
        XCTAssertTrue(model.endAwakeIfDue(now: now.addingTimeInterval(3 * 3600)))
        XCTAssertFalse(model.isAwake)
    }

    func testAClockGoneBackPastTheStartLetsGo() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        XCTAssertTrue(model.endAwakeIfDue(now: now.addingTimeInterval(-60)))
    }

    /// An agent's hold is its own reason to stay up, and the timer somebody
    /// set for themselves must not take it with it.
    func testTheEndNeverDropsAnAgentsHold() {
        let (model, ledger) = makeModel()
        // On battery too, so the answer does not depend on the test Mac's cable.
        model.awakeWhileAgentsWorkOnBattery = true
        model.agentsWorking(true)
        XCTAssertTrue(model.isHeldForAgents)

        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        XCTAssertTrue(model.endAwakeIfDue(now: now.addingTimeInterval(30 * 60)))
        XCTAssertFalse(model.isAwake)
        XCTAssertTrue(model.isHeldForAgents)
        XCTAssertEqual(ledger.reasons, [Self.agentReason])
    }

    func testAddingTimeMovesTheEnd() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        model.addAwakeTime(now: now.addingTimeInterval(60))
        XCTAssertEqual(model.awakeUntil, now.addingTimeInterval(60 * 60))
        XCTAssertFalse(model.endAwakeIfDue(now: now.addingTimeInterval(30 * 60)))
        XCTAssertTrue(model.isAwake)
    }

    /// Picking again while held moves the end and keeps the hold: taking a
    /// fresh assertion would let go of the old one first.
    func testPickingAgainWhileHeldOnlyMovesTheEnd() {
        let (model, ledger) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        model.keepAwake(.lasting(minutes: 120), now: now)
        XCTAssertEqual(ledger.taken, 1)
        XCTAssertEqual(model.awakeUntil, now.addingTimeInterval(120 * 60))
        model.keepAwake(.untilTurnedOff, now: now)
        XCTAssertNil(model.awakeUntil)
        XCTAssertEqual(ledger.taken, 1)
    }

    func testTurningTheSwitchOffEndsTheTimer() {
        let (model, ledger) = makeModel()
        model.keepAwake(.lasting(minutes: 30))
        model.activate(.awake)
        XCTAssertFalse(model.isAwake)
        XCTAssertNil(model.awakeUntil)
        XCTAssertNil(model.failure, "a press is never reported as the timer's doing")
        XCTAssertEqual(ledger.reasons, [])
    }

    /// The same stays-until-seen rule as the cutoff's line.
    func testTheEndedLineStaysUntilSeenThenGoes() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        let end = now.addingTimeInterval(30 * 60)
        model.endAwakeIfDue(now: end)

        let firstLook = end.addingTimeInterval(3 * 3600)
        model.railShown(now: firstLook)
        model.railShown(now: firstLook.addingTimeInterval(KeepAwakePolicy.stoppedNoticeAfterSeen - 1))
        XCTAssertEqual(model.failure?.sentence, KeepAwakeTimer.endedMessage)
        model.railShown(now: firstLook.addingTimeInterval(KeepAwakePolicy.stoppedNoticeAfterSeen))
        XCTAssertNil(model.failure)
    }

    /// A new hold clears the line about the old one.
    func testANewHoldClearsTheEndedLine() {
        let (model, _) = makeModel()
        let now = Date()
        model.keepAwake(.lasting(minutes: 30), now: now)
        model.endAwakeIfDue(now: now.addingTimeInterval(30 * 60))
        model.keepAwake(.lasting(minutes: 60))
        XCTAssertNil(model.failure)
    }

    func testThePickedTimeIsRemembered() {
        let (model, _) = makeModel()
        let eight = KeepAwakeTimer.TimeOfDay(hour: 8, minute: 0)
        model.keepAwake(.until(eight))
        XCTAssertEqual(model.lastUntil, eight)
        XCTAssertEqual(makeModel().0.lastUntil, eight, "a fresh model reads it back")
    }
}
