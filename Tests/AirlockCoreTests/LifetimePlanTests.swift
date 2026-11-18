import CryptoKit
import Foundation
import XCTest
@testable import AirlockCore

/// Lifetime: paid once, through AppSumo. Everything Plus has on the Mac, no
/// online notes, nothing to buy, change or be late paying.
final class LifetimePlanTests: XCTestCase {
    private let issuer = Curve25519.Signing.PrivateKey()
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-16T09:00:00Z")!

    private func sign(_ payload: String) -> String {
        let bytes = Data(payload.utf8)
        let signature = try! issuer.signature(for: bytes)
        return "\(LicenseVerifier.encode(bytes)).\(LicenseVerifier.encode(signature))"
    }

    private func lifetime(renewsIn days: Double = 75) -> License {
        let renews = now.addingTimeInterval(days * 86_400)
        return License(id: "appsumo-0123456789abcdef01234567", email: "", product: "airlock", period: .yearly,
                       issued: now, renewsAt: renews, checkBy: renews.addingTimeInterval(14 * 86_400),
                       ref: "appsumo:appsumo-0123456789abcdef01234567", plan: .lifetime)
    }

    /// Written out by hand, as the Worker's appsumo code mints it.
    func testTheServersLifetimeKeyReadsAsLifetime() {
        let payload = #"{"checkBy":"2027-02-13T09:00:00Z","email":"","id":"appsumo-0123456789abcdef01234567","issued":"2026-11-16T09:00:00Z","machine":null,"period":"yearly","plan":"lifetime","product":"airlock","ref":"appsumo:appsumo-0123456789abcdef01234567","renewsAt":"2027-01-30T09:00:00Z"}"#
        let license = LicenseVerifier.verify(sign(payload), publicKey: issuer.publicKey.rawRepresentation).license
        XCTAssertEqual(license?.plan, .lifetime)
        XCTAssertEqual(AirlockPlan(license!.plan), .lifetime)
        XCTAssertEqual(AirlockPlan.lifetime.label, "Lifetime")
    }

    /// Plus on the Mac, but never online notes, paid or not.
    func testLimitsArePlusWithoutOnlineNotes() {
        let lifetime = PlanSnapshot(plan: .lifetime, isPaid: true).limits
        let plus = PlanSnapshot(plan: .plus, isPaid: true).limits
        XCTAssertFalse(lifetime.writesNotesOnline)
        XCTAssertTrue(plus.writesNotesOnline)
        XCTAssertEqual(lifetime.clipboardShows, plus.clipboardShows)
        XCTAssertEqual(lifetime.oneAgentAtATime, plus.oneAgentAtATime)
        XCTAssertEqual(lifetime.notesListenFor, plus.notesListenFor)
        XCTAssertEqual(lifetime.tellsVoicesApart, plus.tellsVoicesApart)
        XCTAssertEqual(lifetime.dropBoxExtras, plus.dropBoxExtras)
        XCTAssertEqual(lifetime.movesWindows, plus.movesWindows)
        XCTAssertEqual(AirlockPlan.lifetime.rank, AirlockPlan.plus.rank)
    }

    /// The app never prices it or links to a shop for it.
    func testTheCatalogSellsNothing() {
        XCTAssertNil(PlanCatalog.checkoutURL(.lifetime, .yearly))
        XCTAssertNil(PlanCatalog.checkoutURL(.lifetime, .monthly))
        let symbols = PlanCatalog.features(.lifetime).map(\.symbol)
        XCTAssertFalse(symbols.contains("waveform"))
        XCTAssertFalse(symbols.contains("arrow.clockwise"))
        XCTAssertTrue(symbols.contains("person.2.fill"))
        XCTAssertTrue(symbols.contains("terminal"))
    }

    /// Settings › Plans: what it is, and no offer: any subscription key
    /// pasted would take the lifetime key's place.
    func testThePlansPageOffersNothing() {
        let page = PlansPage(entitlement: .licensed(lifetime()), stored: lifetime(), period: .yearly,
                             canAskServer: true, now: now, locale: gb, timeZone: utc)
        XCTAssertEqual(page.current.title, "Lifetime")
        XCTAssertEqual(page.current.summary, PlansPage.lifetimeSummary)
        XCTAssertNil(page.current.price)
        XCTAssertFalse(page.current.manages)
        XCTAssertNil(page.line)
        XCTAssertTrue(page.stepsDown.isEmpty)
    }

    /// Couldn't check yet is never "your payment is late".
    func testOverdueNeverTalksAboutPayment() {
        XCTAssertEqual(LicenseNotice.forIsland(.overdue(lifetime(renewsIn: -40))), .none)
        XCTAssertEqual(LicenseNotice.forIsland(.licensed(lifetime())), .none)
        let page = PlansPage(entitlement: .overdue(lifetime(renewsIn: -40)), stored: lifetime(renewsIn: -40),
                             period: .yearly, canAskServer: true, now: now, locale: gb, timeZone: utc)
        XCTAssertFalse(page.current.manages)
        XCTAssertTrue(page.current.summary.contains("lifetime deal"))
    }

    /// Free to Lifetime says welcome; Plus to Lifetime is the same plan on
    /// the Mac, so it says nothing.
    func testWelcome() {
        let card = WelcomeCard.due(before: .free, after: .licensed(lifetime()))
        XCTAssertEqual(card?.label, "Welcome to Lifetime")
        XCTAssertFalse(card!.rows.isEmpty)
        let plus = License(id: "lic_1", email: "a@b.com", product: "airlock", period: .yearly,
                           issued: now, renewsAt: now.addingTimeInterval(300 * 86_400),
                           checkBy: now.addingTimeInterval(314 * 86_400), ref: "ls-key", plan: .plus)
        XCTAssertNil(WelcomeCard.due(before: .licensed(plus), after: .licensed(lifetime())))
    }

    /// The notes window never sends Lifetime to a Plans page with nothing on it.
    func testNotesOffersNoPlus() {
        var record = NotesComparisonSample.record
        record.notesWriter = .mac(at: record.endedAt!, why: .plan, plan: PlanSnapshot(plan: .lifetime, isPaid: true))
        let page = MeetingFiles.notesPage(for: record, notes: MeetingNotes(summary: "x", todos: []),
                                          writer: record.notesWriter, noModel: nil, locale: gb, timeZone: utc)
        let offered = CallNotesOffers.of(record, page: page, plan: PlanSnapshot(plan: .lifetime, isPaid: true),
                                         online: .init(exists: true, settingOn: true, blocked: false))
        XCTAssertFalse(offered.seePlus)
        XCTAssertNotEqual(offered.redo, .opensPlans)
    }
}
