import XCTest
@testable import AirlockCore

/// The battery's numbers are IOKit's; the sentences are these. The interesting
/// cases are all the same case: macOS very often has no estimate to give, and
/// the wrong answer to that is a confident zero.
final class BatteryReadingTests: XCTestCase {

    // MARK: - No estimate is a state, not a zero

    /// The first minutes after the cable moves — the common case, not an edge
    /// one. "Calculating…" is what the system menu shows; what it must never
    /// show is "0 minutes left" on a battery with hours in it.
    func testAnAbsentEstimateIsNeverRenderedAsZeroMinutes() {
        XCTAssertNil(BatteryReading.duration(minutes: nil))
        XCTAssertNil(BatteryReading.remaining(minutes: nil))
    }

    /// IOKit reports -1 while it is still working one out, and 0 is not a
    /// meaningful answer either.
    func testANonPositiveEstimateCountsAsAbsent() {
        XCTAssertNil(BatteryReading.duration(minutes: -1))
        XCTAssertNil(BatteryReading.duration(minutes: 0))
    }

    func testTheGutterSaysItIsStillCalculatingRatherThanNothingAtAll() {
        XCTAssertEqual(
            BatteryReading.status(percentage: 63, isCharging: false, isPluggedIn: false,
                                  isCharged: false, minutesRemaining: nil),
            "Battery 63%, calculating time left")
        XCTAssertEqual(
            BatteryReading.status(percentage: 63, isCharging: true, isPluggedIn: true,
                                  isCharged: false, minutesRemaining: nil),
            "Battery 63%, charging, calculating time until full")
    }

    // MARK: - Duration

    func testSingularsAreSingular() {
        XCTAssertEqual(BatteryReading.duration(minutes: 1), "1 minute")
        XCTAssertEqual(BatteryReading.duration(minutes: 60), "1 hour")
        XCTAssertEqual(BatteryReading.duration(minutes: 61), "1 hour 1 minute")
        XCTAssertEqual(BatteryReading.remaining(minutes: 1), "1 minute left")
    }

    /// Under an hour it stays in minutes — which is the only range the compact
    /// island's critical rung ever sees, and why sharing this formatter with it
    /// changes none of its wording.
    func testUnderAnHourStaysInMinutes() {
        XCTAssertEqual(BatteryReading.duration(minutes: 18), "18 minutes")
        XCTAssertEqual(BatteryReading.duration(minutes: 59), "59 minutes")
    }

    /// "222 minutes left" is arithmetic, not an answer.
    func testHoursAreSpokenAsHours() {
        XCTAssertEqual(BatteryReading.duration(minutes: 222), "3 hours 42 minutes")
        XCTAssertEqual(BatteryReading.duration(minutes: 120), "2 hours")
        XCTAssertEqual(BatteryReading.remaining(minutes: 222), "3 hours 42 minutes left")
    }

    // MARK: - Status

    func testOnBatteryTheEstimateIsTimeLeft() {
        XCTAssertEqual(
            BatteryReading.status(percentage: 42, isCharging: false, isPluggedIn: false,
                                  isCharged: false, minutesRemaining: 95),
            "Battery 42%, 1 hour 35 minutes left")
    }

    func testChargingCountsTowardsFullNotTowardsEmpty() {
        XCTAssertEqual(
            BatteryReading.status(percentage: 42, isCharging: true, isPluggedIn: true,
                                  isCharged: false, minutesRemaining: 95),
            "Battery 42%, charging, 1 hour 35 minutes until full")
    }

    func testAFullBatteryIsNotStillCharging() {
        XCTAssertEqual(
            BatteryReading.status(percentage: 100, isCharging: false, isPluggedIn: true,
                                  isCharged: true, minutesRemaining: nil),
            "Battery 100%, fully charged")
    }

    /// Plugged in and holding — the 80% charge limit, most of a day at a desk —
    /// is neither charging nor draining. Whatever IOKit leaves in the
    /// time-to-empty field there, a Mac on mains has no "time left", and putting
    /// a number on it would be a lie that sounds authoritative.
    func testPluggedInAndHoldingClaimsNoEstimateEvenWhenHandedOne() {
        XCTAssertEqual(
            BatteryReading.status(percentage: 80, isCharging: false, isPluggedIn: true,
                                  isCharged: false, minutesRemaining: 240),
            "Battery 80%, plugged in, holding the charge to protect the battery")
    }

    /// Holding on the cable is on purpose, so it must never wear the bolt that
    /// means charging.
    func testHoldingIsMarkedWithAPlugNotABolt() {
        XCTAssertEqual(BatteryReading.mark(isCharging: false, isPluggedIn: true, isCharged: false), .holding)
        XCTAssertEqual(BatteryReading.mark(isCharging: true, isPluggedIn: true, isCharged: false), .charging)
        XCTAssertEqual(BatteryReading.mark(isCharging: false, isPluggedIn: true, isCharged: true), .none)
        XCTAssertEqual(BatteryReading.mark(isCharging: false, isPluggedIn: false, isCharged: false), .none)
    }

    /// Charging at 5% draws a nearly empty battery, not a full one.
    func testLevelGlyphFollowsThePercentageWhateverTheCable() {
        XCTAssertEqual(BatteryReading.levelSymbol(percentage: 5), "battery.0")
        XCTAssertEqual(BatteryReading.levelSymbol(percentage: 30), "battery.25")
        XCTAssertEqual(BatteryReading.levelSymbol(percentage: 50), "battery.50")
        XCTAssertEqual(BatteryReading.levelSymbol(percentage: 80), "battery.75")
        XCTAssertEqual(BatteryReading.levelSymbol(percentage: 100), "battery.100")
    }

    // MARK: - The two descriptions of one battery

    /// A critical battery is described twice: by the compact island's rung over
    /// the menu bar, and by the gutter indicator inside the panel. They are
    /// different views of the SAME reading, so the minutes have to match to the
    /// word. Sharing `remaining(minutes:)` is what makes that structural — this
    /// test is here to fail if someone hand-writes one of them again.
    func testTheIslandAndTheGutterSayTheSameThingAboutTheSameBattery() {
        let minutes = 18
        let island = CompactSlot.batteryCritical(minutes: minutes).accessibilityLabel
        let gutter = BatteryReading.status(percentage: 7, isCharging: false, isPluggedIn: false,
                                           isCharged: false, minutesRemaining: minutes)
        XCTAssertEqual(island, "Battery critical, 18 minutes left")
        XCTAssertEqual(gutter, "Battery 7%, 18 minutes left")
        guard let clause = BatteryReading.remaining(minutes: minutes) else {
            return XCTFail("a positive estimate must produce a clause")
        }
        XCTAssertTrue(island?.hasSuffix(clause) == true, island ?? "nil")
        XCTAssertTrue(gutter.hasSuffix(clause), gutter)
    }

    /// And when there is no estimate, neither of them invents one: the island
    /// drops the clause and keeps its glyph, the gutter says it is calculating.
    /// What must not happen is one of the two reading "0 minutes left".
    func testNeitherInventsAnEstimateThatDoesNotExist() {
        XCTAssertEqual(CompactSlot.batteryCritical(minutes: nil).accessibilityLabel,
                       "Battery critical")
        XCTAssertEqual(
            BatteryReading.status(percentage: 7, isCharging: false, isPluggedIn: false,
                                  isCharged: false, minutesRemaining: nil),
            "Battery 7%, calculating time left")
    }
}
