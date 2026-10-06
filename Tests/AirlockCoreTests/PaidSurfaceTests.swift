import XCTest
@testable import AirlockCore

/// What a finished trial takes: everything.
///
/// **This file used to assert the opposite, and it did not stop the change.**
/// It was written when the paid surface was only the agent gate and voice, and
/// its own header warned that "a rename could quietly put it back" — then a
/// rename of `allowsAgentActions` back to `allowsUse` put it back, and every
/// assertion here still passed, because they test the PREDICATE and the
/// predicate did not move. The guard was aimed at the wrong thing: a symbol's
/// name is not the product decision, and only prose noticed.
///
/// So the assertions below are unchanged and the meaning is inverted, which is
/// the honest record of what happened. What has changed is what they are
/// understood to protect: `allowsUse` false now closes the whole panel, and the
/// argument for the previous split is preserved in full on `Entitlement.allowsUse`
/// so that reverting is a decision rather than an excavation.
///
/// A test that could actually have caught this would have to assert about the
/// SURFACES — that the clipboard renders with no licence — and the view layer
/// this app draws with cannot be unit-tested at all. That is the real reason
/// this slipped, and it is worth knowing before trusting the next comment that
/// says a test is guarding a product decision.
final class PaidSurfaceTests: XCTestCase {
    private func license(renewsIn days: Int) -> License {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return License(id: "l", email: "a@b.c", product: "airlock", period: .yearly,
                       issued: now, renewsAt: now.addingTimeInterval(Double(days) * 86_400),
                       checkBy: now.addingTimeInterval(Double(days + 14) * 86_400))
    }

    /// The one state that takes anything — now the whole app rather than two
    /// surfaces. Every other state still belongs to somebody who has paid or is
    /// still trying, and that half has never changed.
    func testOnlyAnExpiredTrialClosesThePaidSurfaces() {
        XCTAssertFalse(Entitlement.trialExpired.allowsUse)

        for entitlement: Entitlement in [
            .trialing(daysRemaining: 0),
            .trialing(daysRemaining: 14),
            .licensed(license(renewsIn: 300)),
            .grace(license(renewsIn: -1)),
            .overdue(license(renewsIn: -30)),
        ] {
            XCTAssertTrue(entitlement.allowsUse,
                          "\(entitlement) belongs to somebody who has paid, or is still trying")
        }
    }

    /// A trial on its LAST day is still a trial. Nothing closes early.
    func testTheLastDayOfATrialStillWorks() {
        XCTAssertTrue(Entitlement.trialing(daysRemaining: 0).allowsUse)
    }

    /// **The invariant that survived the reversal**, and the one that matters
    /// most: a payment problem is never an outage. Grace is silent and overdue
    /// keeps working, so a bad afternoon on the licence server cannot take
    /// somebody's whole app away now that the whole app is what is at stake.
    /// Grace is silent and overdue keeps working — neither is ever an outage,
    /// which is the rule that stops a bad afternoon on the licence server from
    /// taking somebody's notch away mid-task.
    func testAPaymentProblemNeverClosesAnything() {
        XCTAssertTrue(Entitlement.grace(license(renewsIn: -1)).allowsUse)
        XCTAssertTrue(Entitlement.overdue(license(renewsIn: -30)).allowsUse)
    }

    /// The invariant, from the other side: the notice and the entitlement must
    /// agree, or the panel would say one thing and do another.
    func testTheIslandNoticeAgreesWithTheEntitlement() {
        for entitlement: Entitlement in [
            .trialExpired,
            .trialing(daysRemaining: 3),
            .licensed(license(renewsIn: 300)),
            .grace(license(renewsIn: -1)),
            .overdue(license(renewsIn: -30)),
        ] {
            XCTAssertEqual(LicenseNotice.forIsland(entitlement).isBlocking,
                           !entitlement.allowsUse, "\(entitlement)")
        }
    }

    /// A blocked voice action is refused by the outcome, not by the view — so
    /// the refusal cannot be forgotten by a card that renders anyway.
    func testAnUnentitledVoiceActionIsBlockedAtTheOutcome() {
        let request = PermissionRequest(id: "r", toolName: "Voice.AudioOutput",
                                        summary: "Send sound to AirPods",
                                        target: "AirPods", createdAt: Date())
        let outcome = VoiceActionOutcome.resolve(verdict: .ask(risk: nil), for: request,
                                                 isEntitled: false,
                                                 offersStandingPermission: true)
        guard case .blocked = outcome else {
            return XCTFail("an unentitled action must be refused before the policy runs")
        }
    }
}
