import XCTest
@testable import AirlockCore

final class LicenseNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func license(renewsIn days: Double) -> License {
        let renews = now.addingTimeInterval(days * 86_400)
        return License(id: "lic_1", email: "a@b.com", product: "airlock", period: .monthly,
                       issued: now, renewsAt: renews,
                       checkBy: renews.addingTimeInterval(14 * 86_400))
    }

    // MARK: - Silence

    /// The island is where you glance at a build or a meeting. A paid-up
    /// subscription must never put anything billing-shaped in front of that.
    func testAPaidSubscriptionSaysNothing() {
        XCTAssertEqual(LicenseNotice.forIsland(.licensed(license(renewsIn: 20))), .none)
    }

    /// The grace window's entire purpose, restated here so it cannot be lost by
    /// a change in the view: a refresh that could not happen is invisible.
    func testGraceSaysNothing() {
        XCTAssertEqual(LicenseNotice.forIsland(.grace(license(renewsIn: -3))), .none)
    }

    /// Most of a trial is silent too. A countdown running for a fortnight is
    /// just an advert you cannot close.
    func testMostOfTheTrialSaysNothing() {
        XCTAssertEqual(LicenseNotice.forIsland(.trialing(daysRemaining: 14)), .none)
        XCTAssertEqual(LicenseNotice.forIsland(.trialing(daysRemaining: 4)), .none)
    }

    // MARK: - Speaking up

    func testTheLastFewDaysOfATrialAreMentioned() {
        XCTAssertEqual(LicenseNotice.forIsland(.trialing(daysRemaining: 3)),
                       .endingSoon(daysRemaining: 3))
        XCTAssertEqual(LicenseNotice.forIsland(.trialing(daysRemaining: 1)),
                       .endingSoon(daysRemaining: 1))
    }

    /// A warning, not a blockade — the widgets are still there underneath.
    func testAnEndingTrialDoesNotTakeThePanel() {
        XCTAssertFalse(LicenseNotice.forIsland(.trialing(daysRemaining: 1)).isBlocking)
    }

    func testOverdueAsksAboveTheWidgetsRatherThanInsteadOfThem() {
        let notice = LicenseNotice.forIsland(.overdue(license(renewsIn: -40)))
        XCTAssertEqual(notice, .overdue)
        XCTAssertFalse(notice.isBlocking, "they paid; the app keeps working")
    }

    /// The one and only case that takes the panel over.
    func testOnlyAFinishedTrialBlocks() {
        XCTAssertEqual(LicenseNotice.forIsland(.trialExpired), .blocked)
        XCTAssertTrue(LicenseNotice.forIsland(.trialExpired).isBlocking)

        for entitlement: Entitlement in [.licensed(license(renewsIn: 20)),
                                         .grace(license(renewsIn: -3)),
                                         .overdue(license(renewsIn: -40)),
                                         .trialing(daysRemaining: 1)] {
            XCTAssertFalse(LicenseNotice.forIsland(entitlement).isBlocking, "\(entitlement)")
        }
    }

    /// Blocking and `allowsUse` have to agree, or the panel would be taken over
    /// for somebody the rules say is entitled to use the app.
    func testBlockingMatchesTheEntitlementThatStopsUse() {
        for entitlement: Entitlement in [.licensed(license(renewsIn: 20)),
                                         .grace(license(renewsIn: -3)),
                                         .overdue(license(renewsIn: -40)),
                                         .trialing(daysRemaining: 5),
                                         .trialExpired] {
            XCTAssertEqual(LicenseNotice.forIsland(entitlement).isBlocking,
                           !entitlement.allowsUse, "\(entitlement)")
        }
    }

    /// The last-day card was gated on zero days, which a trial never reports:
    /// `resolve` says `.trialing` only while days remain, so the final day is
    /// one. The card was written, designed and unreachable.
    func testTheLastDayIsTheDayWithOneLeft() {
        let trialStarted = now.addingTimeInterval(-13 * 86_400)
        let entitlement = Entitlement.resolve(verdict: nil, trialStarted: trialStarted, now: now)
        XCTAssertEqual(entitlement, .trialing(daysRemaining: 1))
        XCTAssertTrue(LicenseNotice.forIsland(entitlement).isLastDay)

        XCTAssertFalse(LicenseNotice.endingSoon(daysRemaining: 2).isLastDay)
        XCTAssertFalse(LicenseNotice.blocked.isLastDay)
        XCTAssertFalse(LicenseNotice.overdue.isLastDay)
    }
}
