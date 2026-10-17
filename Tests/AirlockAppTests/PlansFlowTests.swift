import AirlockTestSupport
import CryptoKit
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// Getting from a button to a paid plan, and what greets it: every "See
/// plans" opens Settings › Plans on the price that was pressed, a key from
/// anywhere ends the browser hand-off, and "Welcome to Plus" is raised once,
/// for a bigger plan only.
///
/// The first two were the purchase window's tests. Each was wrong once: the
/// monthly button opened on yearly, and a key pasted in Settings left the
/// window waiting for a browser that had nothing more to say.
@MainActor
final class PlansFlowTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var scratch: TestScratch!
    private let issuer = Curve25519.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        suite = "PlansFlowTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        scratch = TestScratch("plans")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        scratch.remove()
        super.tearDown()
    }

    // MARK: - The page it opens on

    func testTheLastDayCardsPriceButtonsOpenOnTheirOwnPeriod() {
        let offers = LastDayCard.offers
        XCTAssertEqual(offers.map(\.plan), [.yearly, .monthly])
        for offer in offers {
            XCTAssertTrue(offer.title.contains(offer.plan.price),
                          "\"\(offer.title)\" opens on \(offer.plan) at \(offer.plan.price)")
        }
    }

    func testAskingForPlansPassesThePeriodThroughAndKeepsIt() {
        let license = LicenseModel(previewing: .trialing(daysRemaining: 1))
        var opened: [Bool] = []
        license.onShowPlans = { opened.append($0) }
        XCTAssertEqual(license.plansPeriod, .yearly, "yearly unless a button says otherwise")

        license.showPlans(period: .monthly)
        XCTAssertEqual(license.plansPeriod, .monthly)

        // A way in that names nothing leaves the switch where it was.
        license.showPlans()
        XCTAssertEqual(license.plansPeriod, .monthly)

        license.showPlans(keyField: true)
        XCTAssertEqual(opened, [false, false, true], "only \"I have a key\" lands on the key field")
    }

    // MARK: - A key from anywhere

    /// Pasted in Settings, arrived from the browser: whichever way, a key
    /// that goes in ends the waiting, and one that is refused leaves it.
    func testAKeyThatGoesInEndsTheWaitingAndARefusedOneDoesNot() async {
        for stalled in [false, true] {
            let license = LicenseModel(previewing: .free,
                                       checkingWith: issuer.publicKey.rawRepresentation,
                                       keepingIn: defaults)
            license.purchase.begin(.plus, .yearly)
            if stalled { license.purchase.setStalled() }
            let waiting = license.purchase.stage

            let refused = await license.apply(token(signedBy: Curve25519.Signing.PrivateKey()))
            XCTAssertFalse(refused)
            XCTAssertEqual(license.purchase.stage, waiting, "a key that did not verify changes nothing")

            let accepted = await license.apply(token(signedBy: issuer))
            XCTAssertTrue(accepted)
            XCTAssertEqual(license.purchase.stage, .activated)
        }
    }

    // MARK: - Welcome to Plus

    func testAPlusKeyOnFreeIsWelcomedOnceAndTheCardOutlivesAQuit() async {
        let model = launch()
        XCTAssertNil(model.welcomeCard)

        await model.apply(token(signedBy: issuer, plan: .plus))
        XCTAssertEqual(model.entitlement.plan, .plus)
        XCTAssertEqual(model.welcomeCard?.plan, .plus)

        XCTAssertEqual(launch().welcomeCard?.plan, .plus, "still there after a quit, until read")

        model.dismissWelcome()
        XCTAssertNil(model.welcomeCard)
        XCTAssertNil(launch().welcomeCard, "\"Got it\" is remembered")

        await model.apply(token(signedBy: issuer, plan: .plus))
        XCTAssertNil(model.welcomeCard, "the same plan pasted again announces nothing")
    }

    func testGoingUpToProIsWelcomedAndGoingDownIsNot() async {
        let model = launch()
        await model.apply(token(signedBy: issuer, plan: .plus))
        model.dismissWelcome()

        await model.apply(token(signedBy: issuer, plan: .pro))
        XCTAssertEqual(model.welcomeCard?.plan, .pro)
        model.dismissWelcome()

        await model.apply(token(signedBy: issuer, plan: .plus))
        XCTAssertNil(model.welcomeCard)
        XCTAssertEqual(model.entitlement.plan, .plus)
    }

    /// A welcome to Pro, still unread on a Mac that is back on Plus, would
    /// thank somebody for something they no longer have.
    func testAWelcomeForAPlanThisMacIsNoLongerOnGoes() async {
        let model = launch()
        await model.apply(token(signedBy: issuer, plan: .pro))
        XCTAssertEqual(model.welcomeCard?.plan, .pro)

        defaults.set(token(signedBy: issuer, plan: .plus), forKey: "license.token")
        XCTAssertNil(launch().welcomeCard)
    }

    // MARK: - Fixtures

    private var marker: URL { scratch.root.appendingPathComponent("Airlock/.trial") }

    /// A fresh model each time, as a launch makes one.
    private func launch() -> LicenseModel {
        LicenseModel(defaults: defaults, trialMarker: marker, publicKey: issuer.publicKey.rawRepresentation)
    }

    /// Signed the way the licence server signs, with no machine named, so it
    /// is good on any Mac.
    private func token(signedBy key: Curve25519.Signing.PrivateKey, plan: License.Plan = .plus) -> String {
        let now = Date()
        let license = License(id: "lic_test", email: "someone@example.com", product: "airlock",
                              period: .monthly, issued: now,
                              renewsAt: now.addingTimeInterval(30 * 86_400),
                              checkBy: now.addingTimeInterval(44 * 86_400), plan: plan)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try! encoder.encode(license)
        let signature = try! key.signature(for: payload)
        return "\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))"
    }
}
