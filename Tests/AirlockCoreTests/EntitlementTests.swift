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
                         period: License.Period = .monthly, plan: License.Plan = .plus) -> License {
        License(id: "lic_1", email: "a@b.com", product: "airlock", period: period,
                issued: now, renewsAt: day(days), checkBy: day(days + grace), plan: plan)
    }

    /// Nil `trialStarted` is a Mac where no trial ever began: every new
    /// install, now that none starts.
    private func resolve(_ verdict: LicenseVerdict?, trialStarted: Date? = nil,
                         subscriptionEnded: Bool = false) -> Entitlement {
        Entitlement.resolve(verdict: verdict, trialStarted: trialStarted,
                            now: now, calendar: calendar, subscriptionEnded: subscriptionEnded)
    }

    // MARK: - A new install

    /// No trial, no card, no countdown: Free, from the first launch.
    func testAFreshInstallIsOnFree() {
        let entitlement = resolve(nil)
        XCTAssertEqual(entitlement, .free)
        XCTAssertEqual(entitlement.plan, .free)
        XCTAssertFalse(entitlement.isPaid)
        XCTAssertFalse(entitlement.limits.writesNotesOnline)
        XCTAssertNil(entitlement.license)
        XCTAssertEqual(entitlement.snapshot, .free)
    }

    // MARK: - A trial from before plans

    /// Honoured to its end, with everything Plus has. A trial has no token to
    /// ask the licence server with, so its notes are written on the Mac.
    func testAnOldTrialCountsDownOnPlus() {
        let entitlement = resolve(nil, trialStarted: day(-10))
        XCTAssertEqual(entitlement, .trialing(daysRemaining: 4))
        XCTAssertEqual(entitlement.plan, .plus)
        XCTAssertFalse(entitlement.isPaid)
        XCTAssertFalse(entitlement.limits.writesNotesOnline)
    }

    /// Run out, it is Free. Nothing locks.
    func testAnExpiredTrialIsFree() {
        XCTAssertEqual(resolve(nil, trialStarted: day(-14)), .free)
        XCTAssertEqual(resolve(nil, trialStarted: day(-400)), .free)
    }

    // MARK: - Paid and in date

    func testALicenceInsideItsTermIsLicensedOnItsPlan() {
        let paid = license(renewsIn: 20, plan: .pro)
        let entitlement = resolve(.valid(paid))
        XCTAssertEqual(entitlement, .licensed(paid))
        XCTAssertEqual(entitlement.plan, .pro)
        XCTAssertTrue(entitlement.isPaid)
        XCTAssertTrue(entitlement.limits.writesNotesOnline)
        XCTAssertEqual(entitlement.snapshot, PlanSnapshot(plan: .pro, isPaid: true))
    }

    func testAKeyFromBeforePlansIsPlus() {
        let old = License(id: "lic_1", email: "a@b.com", product: "airlock", period: .monthly,
                          issued: now, renewsAt: day(20), checkBy: day(34))
        XCTAssertEqual(resolve(.valid(old)).plan, .plus)
    }

    /// A licence outlives the trial: activating on day 30 works, and the trial
    /// having run out is no longer relevant to anything.
    func testALicenceOverridesAFinishedTrial() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: 20)), trialStarted: day(-30)),
                       .licensed(license(renewsIn: 20)))
    }

    // MARK: - Grace

    /// The point of the grace window: past the billing date, nothing refreshed,
    /// and the person using it cannot tell. Same plan, still paid.
    func testGraceIsIndistinguishableFromBeingLicensed() {
        let unrefreshed = license(renewsIn: -3, plan: .pro)
        let entitlement = resolve(.valid(unrefreshed))
        XCTAssertEqual(entitlement, .grace(unrefreshed))
        XCTAssertEqual(entitlement.plan, .pro)
        XCTAssertTrue(entitlement.isPaid, "as far as this Mac can prove, they are paid up")
        XCTAssertTrue(entitlement.limits.writesNotesOnline)
        XCTAssertEqual(LicenseNotice.forIsland(entitlement), .none,
                       "THE point: a bad network is not their problem")
    }

    func testGraceBeginsTheMomentTheBillingDatePasses() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: 0))), .grace(license(renewsIn: 0)))
    }

    func testTheLastMomentOfGraceIsStillGrace() {
        let almost = License(id: "lic_1", email: "a@b.com", product: "airlock",
                             period: .monthly, issued: now,
                             renewsAt: day(-14), checkBy: now.addingTimeInterval(1))
        XCTAssertEqual(resolve(.valid(almost)), .grace(almost))
    }

    // MARK: - Overdue

    /// Past the cutoff it asks, and keeps its plan: a payment problem is never
    /// a downgrade until the server says the subscription ended. Online notes
    /// pause, because the server refuses an overdue key anyway.
    func testOverdueKeepsItsPlanAndAsks() {
        let stale = license(renewsIn: -40, plan: .pro)
        let entitlement = resolve(.valid(stale))
        XCTAssertEqual(entitlement, .overdue(stale))
        XCTAssertEqual(entitlement.plan, .pro)
        XCTAssertFalse(entitlement.isPaid)
        XCTAssertFalse(entitlement.limits.writesNotesOnline)
        XCTAssertEqual(LicenseNotice.forIsland(entitlement), .overdue)
        XCTAssertEqual(entitlement.license?.email, "a@b.com",
                       "say whose it is: that is the support question")
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

    // MARK: - A subscription that ended

    /// The server said no (cancelled, refunded, unpaid): Free, once the paid
    /// period is over, and never before it.
    func testAnEndedSubscriptionIsFreeOnlyAfterItsPaidPeriod() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: 10)), subscriptionEnded: true),
                       .licensed(license(renewsIn: 10)), "a refusal never cuts a paid period short")
        XCTAssertEqual(resolve(.valid(license(renewsIn: -1)), subscriptionEnded: true), .free)
        XCTAssertEqual(resolve(.valid(license(renewsIn: -40)), subscriptionEnded: true), .free,
                       "not overdue: they stopped paying, so it does not keep asking")
    }

    /// Ended with a trial from before plans still running: the trial was the
    /// thing ending anyway, and Free is where both land.
    func testAnEndedSubscriptionIgnoresAnOldTrial() {
        XCTAssertEqual(resolve(.valid(license(renewsIn: -1)), trialStarted: day(-3),
                               subscriptionEnded: true), .free)
    }

    // MARK: - Rubbish keys

    /// A forged key is not a lapse and earns no grace. It counts as no key:
    /// an old trial with days left keeps them, and otherwise it is Free.
    func testAnInvalidKeyCountsAsNoKey() {
        XCTAssertEqual(resolve(.invalid(.signature), trialStarted: day(-3)),
                       .trialing(daysRemaining: 11))
        XCTAssertEqual(resolve(.invalid(.signature), trialStarted: day(-30)), .free)
        XCTAssertEqual(resolve(.invalid(.wrongProduct)), .free)
        XCTAssertEqual(resolve(.invalid(.otherMachine)), .free)
    }

    // MARK: - The whole life of a subscription, in order

    /// Read top to bottom, this is the contract: one month paid, a fortnight of
    /// silence, then asking, and never, at any point, Free unless the server
    /// said the subscription ended.
    func testASubscriptionKeepsItsPlanUntilTheServerEndsIt() {
        let renews = day(30)
        let subscription = License(id: "lic_1", email: "a@b.com", product: "airlock",
                                   period: .monthly, issued: now, renewsAt: renews,
                                   checkBy: renews.addingTimeInterval(14 * 86_400), plan: .pro)
        let timeline: [(Double, Bool, LicenseNotice)] = [
            // days from now, isPaid, what the island says
            (0,  true, .none),
            (29, true, .none),
            (31, true, .none),       // grace: billing date passed, still silent
            (43, true, .none),       // last day of grace
            (45, false, .overdue),   // overdue: asks
            (400, false, .overdue),  // and keeps asking, still on Pro
        ]
        for (offset, paid, notice) in timeline {
            let entitlement = Entitlement.resolve(verdict: .valid(subscription), trialStarted: nil,
                                                  now: day(offset), calendar: calendar)
            XCTAssertEqual(entitlement.plan, .pro, "day \(offset)")
            XCTAssertEqual(entitlement.isPaid, paid, "day \(offset)")
            XCTAssertEqual(LicenseNotice.forIsland(entitlement), notice, "day \(offset)")
        }
    }
}
