import AirlockTestSupport
import CryptoKit
import XCTest
import AirlockCore
@testable import AirlockApp

/// Every way a Mac lands on Free, through the real `LicenseModel` on a
/// throwaway preferences suite and trial marker: a new install, an old trial
/// running out, a subscription cancelled or refunded, and a key that no
/// longer works here. In each, Airlock keeps working, the key stays where it
/// was, and "You're on Free now" is due once, saying the right thing.
@MainActor
final class WaysIntoFreeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var scratch: TestScratch!
    private let issuer = Curve25519.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        suite = "WaysIntoFreeTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        scratch = TestScratch("free")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        scratch.remove()
        super.tearDown()
    }

    private var marker: URL { scratch.root.appendingPathComponent("Airlock/.trial") }

    /// A fresh model each time, as a launch makes one.
    private func launch() -> LicenseModel {
        LicenseModel(defaults: defaults, trialMarker: marker, publicKey: issuer.publicKey.rawRepresentation)
    }

    private func token(renewsIn days: Double, plan: License.Plan = .plus, machine: String? = nil) -> String {
        let renews = Date().addingTimeInterval(days * 86_400)
        let license = License(id: "lic_test", email: "someone@example.com", product: "airlock",
                              period: .monthly, issued: renews.addingTimeInterval(-30 * 86_400),
                              renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400),
                              machine: machine, plan: plan)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try! encoder.encode(license)
        let signature = try! issuer.signature(for: payload)
        return "\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))"
    }

    // MARK: - New install

    /// No trial, no countdown, no card, and nothing written that would start
    /// one: a later launch is on Free too.
    func testANewInstallStartsOnFreeAndStartsNoTrial() {
        let model = launch()
        XCTAssertEqual(model.entitlement, .free)
        XCTAssertEqual(model.entitlement.plan, .free)
        XCTAssertNil(model.freeCard, "nothing ended, so there is nothing to tell")
        XCTAssertNil(model.trialStart())
        XCTAssertNil(defaults.object(forKey: "license.trialStarted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no trial marker written")

        XCTAssertEqual(launch().entitlement, .free)
    }

    // MARK: - An old trial

    /// A trial running at the update keeps its days, with everything Plus has.
    func testAnOldTrialKeepsItsDays() {
        defaults.set(Date().addingTimeInterval(-3 * 86_400), forKey: "license.trialStarted")
        let model = launch()
        guard case .trialing(let days) = model.entitlement else { return XCTFail("\(model.entitlement)") }
        XCTAssertEqual(days, TrialClock.length - 3)
        XCTAssertEqual(model.entitlement.plan, .plus)
        XCTAssertNil(model.freeCard)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the second copy is healed")
    }

    /// Run out, it is Free, and the card says the trial ended and lists
    /// Free's limits. Not notes online: a trial never wrote them.
    func testAnOldTrialRunningOutMovesToFree() throws {
        defaults.set(Date().addingTimeInterval(-3 * 86_400), forKey: "license.trialStarted")
        _ = launch()
        defaults.set(Date().addingTimeInterval(-20 * 86_400), forKey: "license.trialStarted")

        let model = launch()
        XCTAssertEqual(model.entitlement, .free)
        let card = try XCTUnwrap(model.freeCard)
        XCTAssertEqual(card.before.ending, .trial)
        XCTAssertEqual(card.changes, [.shorterClipboard, .oneAgentAtATime, .shorterCallNotes, .voicesTogether,
                                      .dropBoxBasics])
        XCTAssertTrue(card.message(now: Date()).hasPrefix("Your trial ended on"))
    }

    /// The first launch of this version on a Mac whose trial ran out under
    /// the old one, which remembered no plan: the card is still due.
    func testATrialThatEndedBeforeTheUpdateStillGetsItsCard() throws {
        defaults.set(Date().addingTimeInterval(-40 * 86_400), forKey: "license.trialStarted")
        let model = launch()
        XCTAssertEqual(model.entitlement, .free)
        XCTAssertEqual(try XCTUnwrap(model.freeCard).before.ending, .trial)
    }

    // MARK: - A subscription

    /// Cancelled or refunded, the licence server declines the next renewal
    /// once the paid period is over. Free, the key kept, and the card names
    /// the plan and what changes.
    func testACancelledOrRefundedSubscriptionMovesToFreeAndKeepsTheKey() throws {
        let key = token(renewsIn: 20, plan: .pro)
        defaults.set(key, forKey: "license.token")
        XCTAssertEqual(launch().entitlement.plan, .pro)

        let ended = token(renewsIn: -1, plan: .pro)
        defaults.set(ended, forKey: "license.token")
        defaults.set(true, forKey: "license.subscriptionEnded")
        let model = launch()

        XCTAssertEqual(model.entitlement, .free)
        XCTAssertEqual(model.token, ended, "the key is not deleted")
        XCTAssertEqual(defaults.string(forKey: "license.token"), ended)
        let card = try XCTUnwrap(model.freeCard)
        XCTAssertEqual(card.before.plan.plan, .pro)
        XCTAssertEqual(card.changes, [.shorterClipboard, .oneAgentAtATime, .shorterCallNotes, .voicesTogether,
                                      .dropBoxBasics, .notesOnTheMac])
        XCTAssertTrue(card.message(now: Date()).hasPrefix("Your Pro subscription ended on"),
                      card.message(now: Date()))
    }

    /// A refusal never cuts a paid period short: until the date it was paid
    /// up to, it is still the plan that was bought.
    func testADeclinedRenewalWaitsForThePaidPeriodToEnd() {
        defaults.set(token(renewsIn: 10), forKey: "license.token")
        defaults.set(true, forKey: "license.subscriptionEnded")
        let model = launch()
        XCTAssertEqual(model.entitlement.plan, .plus)
        XCTAssertTrue(model.entitlement.isPaid)
        XCTAssertNil(model.freeCard)
    }

    /// A key that stops checking out here (made for another Mac) is Free
    /// too, and says so in its own words rather than "ended".
    func testAKeyThatNoLongerWorksHereMovesToFree() throws {
        defaults.set(token(renewsIn: 20), forKey: "license.token")
        _ = launch()

        let elsewhere = token(renewsIn: 20, machine: "a-different-mac")
        defaults.set(elsewhere, forKey: "license.token")
        let model = launch()

        XCTAssertEqual(model.entitlement, .free)
        XCTAssertEqual(model.token, elsewhere, "the key is not deleted")
        let card = try XCTUnwrap(model.freeCard)
        XCTAssertEqual(card.message(now: Date()).components(separatedBy: ". ").first,
                       "Your Plus licence no longer works on this Mac")
    }

    /// Without the signing key a build verifies nothing, so a key on disk
    /// counts for nothing: Free, never "licensed" by default.
    func testABuildThatCannotCheckKeysIsOnFree() {
        defaults.set(token(renewsIn: 20), forKey: "license.token")
        let model = LicenseModel(defaults: defaults, trialMarker: marker, publicKey: nil)
        XCTAssertEqual(model.entitlement, .free)
    }

    // MARK: - The card, once

    /// "Got it" is for good: the card does not come back on the next launch.
    /// A new paid plan that ends later gets a card of its own.
    func testTheCardShowsOnceForEachEnding() {
        defaults.set(token(renewsIn: 20), forKey: "license.token")
        _ = launch()
        defaults.set(token(renewsIn: -1), forKey: "license.token")
        defaults.set(true, forKey: "license.subscriptionEnded")

        let model = launch()
        XCTAssertNotNil(model.freeCard)
        model.dismissFreeCard()
        XCTAssertNil(model.freeCard)
        XCTAssertNil(launch().freeCard, "seen")

        defaults.set(false, forKey: "license.subscriptionEnded")
        defaults.set(token(renewsIn: 30), forKey: "license.token")
        XCTAssertEqual(launch().entitlement.plan, .plus, "subscribed again")
        defaults.set(token(renewsIn: -1), forKey: "license.token")
        defaults.set(true, forKey: "license.subscriptionEnded")
        XCTAssertNotNil(launch().freeCard, "a new ending, a new card")
    }
}
