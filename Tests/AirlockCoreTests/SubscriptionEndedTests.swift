import XCTest
@testable import AirlockCore

/// What happens when a subscription genuinely ends — and, far more importantly,
/// what must not happen when it merely looks like it might have.
///
/// **The hole this closes: one month bought the app forever.** A cancelled
/// subscription's last token aged past `checkBy` into `.overdue`, and `.overdue`
/// kept working and asked. Nothing distinguished "they stopped paying" from "we
/// have not managed to ask lately", so nothing could ever stop.
///
/// The distinction is now a single fact — the server was asked and said no —
/// and it arrives only as a 402. Every indeterminate outcome at Lemon Squeezy
/// throws a 5xx instead, so an outage there cannot reach this flag at all.
final class SubscriptionEndedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func license(renewsInDays: Int) -> License {
        License(id: "l", email: "a@b.c", product: "airlock", period: .monthly,
                issued: t0,
                renewsAt: t0.addingTimeInterval(Double(renewsInDays) * 86_400),
                checkBy: t0.addingTimeInterval(Double(renewsInDays + 14) * 86_400),
                ref: "sub_1")
    }

    private func resolve(_ license: License, ended: Bool, daysAfterIssue: Int) -> Entitlement {
        Entitlement.resolve(verdict: .valid(license),
                            trialStarted: t0.addingTimeInterval(-90 * 86_400),
                            now: t0.addingTimeInterval(Double(daysAfterIssue) * 86_400),
                            subscriptionEnded: ended)
    }

    // MARK: - The hole

    /// THE regression. Past `checkBy` with the server having said no, the
    /// plan ends and the Mac is on Free. This is the case that used to keep
    /// its plan forever.
    func testARefusedSubscriptionMovesToFree() {
        let entitlement = resolve(license(renewsInDays: 30), ended: true, daysAfterIssue: 60)
        XCTAssertEqual(entitlement, .free)
        XCTAssertFalse(entitlement.limits.writesNotesOnline)
    }

    /// And in grace too: grace is patience for a payment that might still
    /// land, not for one that has been confirmed dead.
    func testARefusedSubscriptionDoesNotGetTheGraceWindow() {
        XCTAssertEqual(resolve(license(renewsInDays: 30), ended: true, daysAfterIssue: 35), .free)
    }

    // MARK: - What must NOT happen

    /// **The rule everything else is subordinate to.** Without a refusal, the
    /// dates behave exactly as they always have: grace is silent, overdue keeps
    /// its plan. A customer offline for a month is not a customer who cancelled.
    func testTimeAloneNeverEndsALicence() {
        for day in [35, 60, 400] {
            let entitlement = resolve(license(renewsInDays: 30), ended: false, daysAfterIssue: day)
            XCTAssertNotEqual(entitlement, .free, "day \(day) with no refusal keeps its plan")
            XCTAssertEqual(entitlement.plan, .plus, "day \(day)")
        }
    }

    /// A period already paid for is untouchable, even by a refusal. Cancelling
    /// means "will not renew": `terms.html` promises exactly this in writing,
    /// and the Worker mints through `ends_at` before it ever refuses.
    func testAPaidPeriodSurvivesEvenARefusal() {
        let entitlement = resolve(license(renewsInDays: 30), ended: true, daysAfterIssue: 5)
        guard case .licensed = entitlement else {
            return XCTFail("they paid through day 30; a refusal on day 5 must not shorten that")
        }
        XCTAssertTrue(entitlement.isPaid)
    }

    /// The flag is about a licence, never about a trial. Someone mid-trial has
    /// no subscription to end.
    func testATrialIsUnaffected() {
        let entitlement = Entitlement.resolve(verdict: nil, trialStarted: t0,
                                              now: t0.addingTimeInterval(3 * 86_400),
                                              subscriptionEnded: true)
        XCTAssertEqual(entitlement, .trialing(daysRemaining: 11))
    }

    /// Default false, so every existing caller keeps the old behaviour and the
    /// new one is opt-in at exactly one site.
    func testTheFlagDefaultsToOff() {
        let byDefault = Entitlement.resolve(verdict: .valid(license(renewsInDays: 30)),
                                            trialStarted: t0, now: t0.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(byDefault, .overdue(license(renewsInDays: 30)))
    }
}
