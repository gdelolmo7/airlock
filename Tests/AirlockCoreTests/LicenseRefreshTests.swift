import XCTest
@testable import AirlockCore

final class LicenseRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    private func license(renewsIn days: Double, grace: Double = 14) -> License {
        let renews = now.addingTimeInterval(self.days(days))
        return License(id: "lic_1", email: "a@b.com", product: "airlock",
                       period: .monthly, issued: now,
                       renewsAt: renews,
                       checkBy: renews.addingTimeInterval(self.days(grace)))
    }

    private func shouldAttempt(_ license: License?, lastAttempt: Date? = nil) -> Bool {
        LicenseRefresh.shouldAttempt(license: license, lastAttempt: lastAttempt, now: now)
    }

    // MARK: - Silence is the default

    /// The property the whole design rests on: an unpaid copy never touches the
    /// network for licensing, because there is no token for a server to renew.
    func testATrialNeverRefreshes() {
        XCTAssertFalse(shouldAttempt(nil))
    }

    /// A yearly subscriber goes almost a year without a single request.
    func testALicenceFarFromRenewalIsLeftAlone() {
        XCTAssertFalse(shouldAttempt(license(renewsIn: 355)))
        XCTAssertFalse(shouldAttempt(license(renewsIn: 30)))
        XCTAssertFalse(shouldAttempt(license(renewsIn: 10.5)))
    }

    // MARK: - Trying early, and for a long time

    /// Ten days of chances BEFORE anything is wrong. That lead time is what
    /// turns "the server was down" into a non-event.
    func testItStartsTryingTenDaysAhead() {
        XCTAssertTrue(shouldAttempt(license(renewsIn: 10)))
        XCTAssertTrue(shouldAttempt(license(renewsIn: 3)))
    }

    /// Past the billing date and inside grace — this is exactly when a refresh
    /// matters most, so it must not stop.
    func testItKeepsTryingThroughTheGraceWindow() {
        XCTAssertTrue(shouldAttempt(license(renewsIn: -1)))
        XCTAssertTrue(shouldAttempt(license(renewsIn: -13)))
    }

    /// And past the cutoff too: someone whose subscription is overdue is the
    /// person most likely to have just fixed their card.
    func testItStillTriesOnceOverdue() {
        XCTAssertTrue(shouldAttempt(license(renewsIn: -40)))
    }

    // MARK: - Backing off

    func testItWaitsBetweenAttempts() {
        let recent = now.addingTimeInterval(-3_600)
        XCTAssertFalse(shouldAttempt(license(renewsIn: 3), lastAttempt: recent),
                       "an hour ago is too soon")
    }

    func testItTriesAgainAfterTheInterval() {
        let old = now.addingTimeInterval(-LicenseRefresh.minimumInterval - 60)
        XCTAssertTrue(shouldAttempt(license(renewsIn: 3), lastAttempt: old))
    }

    /// Backoff must never override the "not yet" rule, or a Mac that has been
    /// asleep for a week would refresh a licence that renews in six months.
    func testAnOldAttemptDoesNotForceAnEarlyRefresh() {
        let old = now.addingTimeInterval(-days(30))
        XCTAssertFalse(shouldAttempt(license(renewsIn: 200), lastAttempt: old))
    }

    /// A last-attempt stamp in the future means the clock moved backwards.
    /// Ignoring it beats being locked out of refreshing until the date arrives.
    func testAFutureAttemptStampDoesNotWedgeRefreshing() {
        XCTAssertTrue(shouldAttempt(license(renewsIn: 3),
                                    lastAttempt: now.addingTimeInterval(days(400))))
    }
}
