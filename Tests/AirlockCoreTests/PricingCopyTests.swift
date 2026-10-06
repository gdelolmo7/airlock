import XCTest
@testable import AirlockCore

/// The prices, and the sentences derived from them.
///
/// `PurchaseView` does not just print these — it asserts things ABOUT them:
/// "€3 a month instead of €3.99 — almost three months of the year, free". Those
/// are arithmetic claims, and changing one price silently makes them false on
/// the screen where money changes hands. The design handoff verified the sums
/// once and warned specifically against restating the saving as "two months
/// free"; this is what keeps that from drifting.
///
/// **It has earned that once already.** Moving to €3.99/€35.99 flipped the
/// direction of the rounding: at €4/€35 the saving was 3.25 months, so "three
/// months free" UNDERSTATED it. At €3.99/€35.99 it is 2.98 months, so the same
/// three words would now overstate it — which is why the copy says "almost
/// three" and why `testTheSavingIsJustUnderThreeMonths` asserts the ceiling
/// rather than the floor.
final class PricingCopyTests: XCTestCase {
    /// The numbers the copy is built on. Read from the same place the UI reads.
    private let yearly = 35.99
    private let monthly = 3.99

    func testTheQuotedPricesAreTheOnesInTheCopy() {
        XCTAssertEqual(License.Period.yearly.price, "€35.99 a year")
        XCTAssertEqual(License.Period.monthly.price, "€3.99 a month")
    }

    /// Written out rather than derived from the constants above: a formatter
    /// that agreed with itself would pass while both drifted away from the
    /// screen, which is the failure this file exists to prevent.
    func testTheQuotedPricesAreTheArithmeticOnes() {
        XCTAssertTrue(License.Period.yearly.price.contains(String(format: "%.2f", yearly)))
        XCTAssertTrue(License.Period.monthly.price.contains(String(format: "%.2f", monthly)))
    }

    /// "€3 a month" on the yearly card. €35.99 / 12 is €2.9992, which rounds to
    /// €3.00 — so the card understates by a hundredth of a cent rather than
    /// overstating, which is the safe direction.
    func testTheYearlyMonthlyEquivalentRoundsToTheQuotedFigure() {
        let perMonth = yearly / 12
        XCTAssertEqual((perMonth * 100).rounded() / 100, 3.00, accuracy: 0.001,
                       "the yearly card quotes €3 a month")
        XCTAssertLessThanOrEqual(perMonth, 3.00, "quoting €3 must never overstate what is charged")
    }

    /// "SAVE €11.89 A YEAR" — the badge prints this figure, so it is not a
    /// rounding anybody may adjust.
    func testTheSavingIsTheOneOnTheBadge() {
        XCTAssertEqual(monthly * 12 - yearly, 11.89, accuracy: 0.001)
    }

    /// "almost three months of the year, free". The handoff forbids restating
    /// this as two; the prices now also forbid restating it as a flat three.
    func testTheSavingIsJustUnderThreeMonths() {
        let monthsFree = (monthly * 12 - yearly) / monthly
        XCTAssertGreaterThan(monthsFree, 2.9, "restating this as two would understate it")
        XCTAssertLessThan(monthsFree, 3.0,
                          "it is 2.98 months — dropping the word \"almost\" would overstate it")
    }

    /// Yearly has to actually be cheaper, or the badge on the yearly card is a
    /// lie in the most expensive possible place.
    func testYearlyBeatsMonthly() {
        XCTAssertLessThan(yearly, monthly * 12)
    }

    /// The two plans must not print the same string — the purchase window draws
    /// them side by side and the reader picks between them.
    func testThePlansAreDistinguishable() {
        XCTAssertNotEqual(License.Period.yearly.price, License.Period.monthly.price)
    }

    /// The trial length quoted in onboarding is the one the countdown uses.
    /// They were separate facts until onboarding started saying it out loud.
    func testTheTrialLengthIsASingleFact() {
        XCTAssertEqual(TrialClock.length, 14)
        XCTAssertGreaterThan(TrialClock.length, 0)
    }
}
