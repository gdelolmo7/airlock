import XCTest
@testable import AirlockCore

final class EntitlementTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    private lazy var now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    private func day(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    private func license(renewsIn days: Double, grace: Double = 14,
                         period: License.Period = .monthly) -> License {
        License(id: "lic_1", email: "a@b.com", product: "airlock", period: period,
                issued: now, renewsAt: day(days), checkBy: day(days + grace))
    }

    private func resolve(_ verdict: LicenseVerdict?, trialStarted: Date? = nil) -> Entitlement {
        Entitlement.resolve(verdict: verdict, trialStarted: trialStarted ?? now,
                            now: now, calendar: calendar)
    }

    // MARK: - The trial

    func testAFreshInstallIsOnTrialWithEverythingWorking() {
        let entitlement = resolve(nil)
        XCTAssertEqual(entitlement, .trialing(daysRemaining: 14))
        XCTAssertTrue(entitlement.allowsUse)
        XCTAssertFalse(entitlement.isNagging, "a countdown, not a demand")
        XCTAssertFalse(entitlement.isPaid)
    }

    func testTheTrialCountsDown() {
        XCTAssertEqual(resolve(nil, trialStarted: day(-10)), .trialing(daysRemaining: 4))
    }

    /// The one and only state that stops the app working. Every other state
    /// belongs to somebody who has paid.
    func testAnExpiredTrialIsTheOnlyThingThatGates() {
        let entitlement = resolve(nil, trialStarted: day(-14))
        XCTAssertEqual(entitlement, .trialExpired)
        XCTAssertFalse(entitlement.allowsUse)
        XCTAssertTrue(entitlement.isNagging)
    }

    // MARK: - Paid and in date

    func testALicenceInsideItsTermIsSimplyLicensed() {
        let paid = license(renewsIn: 20)
        let entitlement = resolve(.valid(paid))
        XCTAssertEqual(entitlement, .licensed(paid))
        XCTAssertTrue(entitlement.allowsUse)
        XCTAssertTrue(entitlement.isPaid)
        XCTAssertFalse(entitlement.isNagging)
    }

    /// A licence outlives the trial: activating on day 30 works, and the trial
    /// having run out is no longer relevant to anything.
    func testALicenceOverridesAFinishedTrial() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: 20)), trialStarted: day(-30)),
                       .licensed(license(renewsIn: 20)))
    }

    // MARK: - Grace

    /// The point of the grace window: past the billing date, nothing refreshed,
    /// and the person using it cannot tell. No badge, no banner, no nag.
    func testGraceIsIndistinguishableFromBeingLicensed() {
        let unrefreshed = license(renewsIn: -3)
        let entitlement = resolve(.valid(unrefreshed))
        XCTAssertEqual(entitlement, .grace(unrefreshed))
        XCTAssertTrue(entitlement.allowsUse)
        XCTAssertTrue(entitlement.isPaid, "as far as this Mac can prove, they are paid up")
        XCTAssertFalse(entitlement.isNagging, "THE point — a bad network is not their problem")
    }

    func testGraceBeginsTheMomentTheBillingDatePasses() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: 0))), .grace(license(renewsIn: 0)))
    }

    func testTheLastMomentOfGraceIsStillGrace() {
        let almost = License(id: "lic_1", email: "a@b.com", product: "airlock",
                             period: .monthly, issued: now,
                             renewsAt: day(-14), checkBy: now.addingTimeInterval(1))
        XCTAssertEqual(resolve(.valid(almost)), .grace(almost))
        XCTAssertFalse(resolve(.valid(almost)).isNagging)
    }

    // MARK: - Overdue

    /// Past the cutoff it asks — but it still runs. A failed card must never
    /// become an outage in the middle of somebody's work.
    func testOverdueAsksWithoutLockingAnybodyOut() {
        let stale = license(renewsIn: -40)
        let entitlement = resolve(.valid(stale))
        XCTAssertEqual(entitlement, .overdue(stale))
        XCTAssertTrue(entitlement.allowsUse, "still their app; this is a request")
        XCTAssertTrue(entitlement.isNagging)
        XCTAssertFalse(entitlement.isPaid)
        XCTAssertEqual(entitlement.license?.email, "a@b.com",
                       "say whose it is — that is the support question")
    }

    func testTheCutoffIsTheBoundaryBetweenSilenceAndAsking() {
        let atCutoff = License(id: "lic_1", email: "a@b.com", product: "airlock",
                               period: .monthly, issued: now,
                               renewsAt: day(-14), checkBy: now)
        XCTAssertEqual(resolve(.valid(atCutoff)), .overdue(atCutoff))
    }

    /// A yearly licence gets the same treatment, so nothing in the rules reads
    /// the period. It exists for wording in Settings and nothing else.
    func testThePeriodDoesNotChangeAnyRule() {
        let yearly = license(renewsIn: -3, period: .yearly)
        XCTAssertEqual(resolve(.valid(yearly)), .grace(yearly))
    }

    // MARK: - Rubbish keys

    /// A forged key is not a lapse and does not earn a grace window. It falls
    /// back to the trial — so pasting nonsense on day three leaves eleven days,
    /// and pasting nonsense on day thirty does not produce a working app.
    func testAnInvalidKeyFallsBackToTheTrialRatherThanLapsing() {
        XCTAssertEqual(resolve(.invalid(.signature), trialStarted: day(-3)),
                       .trialing(daysRemaining: 11))
        XCTAssertEqual(resolve(.invalid(.signature), trialStarted: day(-30)), .trialExpired)
        XCTAssertEqual(resolve(.invalid(.wrongProduct), trialStarted: day(-30)), .trialExpired)
    }

    // MARK: - The whole life of a subscription, in order

    /// Read top to bottom, this is the contract: one month paid, a fortnight of
    /// silence, then asking — and never, at any point, an app that stops.
    func testASubscriptionDegradesInThatOrderAndNeverStops() {
        let renews = day(30)
        let subscription = License(id: "lic_1", email: "a@b.com", product: "airlock",
                                   period: .monthly, issued: now,
                                   renewsAt: renews,
                                   checkBy: renews.addingTimeInterval(14 * 86_400))
        let timeline: [(Double, Bool, Bool)] = [
            // days from now, allowsUse, isNagging
            (0,  true, false),
            (29, true, false),
            (31, true, false),   // grace: billing date passed, still silent
            (43, true, false),   // last day of grace
            (45, true, true),    // overdue: asks
            (400, true, true),   // and keeps asking, forever, still working
        ]
        for (offset, allows, nags) in timeline {
            let entitlement = Entitlement.resolve(verdict: .valid(subscription),
                                                  trialStarted: now, now: day(offset),
                                                  calendar: calendar)
            XCTAssertEqual(entitlement.allowsUse, allows, "day \(offset)")
            XCTAssertEqual(entitlement.isNagging, nags, "day \(offset)")
        }
    }

    // MARK: - Free (since 1.0.15)

    /// Free outranks everything: an expired trial, a lapsed subscription that
    /// was ended, and a live licence all read as free, and free is never
    /// blocked, never paid and never asks.
    func testFreeOutranksEveryOtherStateAndNeverStops() {
        let expiredTrial = Entitlement.resolve(verdict: nil, trialStarted: day(-60), now: now,
                                               calendar: calendar, free: true)
        let ended = Entitlement.resolve(verdict: .valid(license(renewsIn: -3)), trialStarted: day(-60),
                                        now: now, calendar: calendar, subscriptionEnded: true, free: true)
        let live = Entitlement.resolve(verdict: .valid(license(renewsIn: 20)), trialStarted: now,
                                       now: now, calendar: calendar, free: true)
        for entitlement in [expiredTrial, ended, live] {
            XCTAssertEqual(entitlement, .free)
            XCTAssertTrue(entitlement.allowsUse)
            XCTAssertFalse(entitlement.isPaid)
            XCTAssertFalse(entitlement.isNagging)
            XCTAssertNil(entitlement.license)
            XCTAssertEqual(LicenseNotice.forIsland(entitlement), .none)
        }
    }

    /// The paid rules are switched off, not deleted: without `free` they are
    /// exactly what they were.
    func testThePaidRulesStillHoldWhenNotFree() {
        XCTAssertEqual(Entitlement.resolve(verdict: nil, trialStarted: day(-60), now: now,
                                           calendar: calendar), .trialExpired)
    }

    func testAirlockIsSold() {
        XCTAssertFalse(Pricing.isFree, "sold again from 1.0.17, the owner's call 2026-10-06; true makes every copy free")
    }
}
