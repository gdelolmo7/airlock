import XCTest
@testable import AirlockCore

/// The four links that take money.
///
/// Nothing guarded these until the store went live, and they are the easiest
/// thing in the app to get quietly wrong. Three ways, each of which these tests
/// close:
///
/// 1. **The same uuid pasted twice.** Both buttons then work, both charge, and
///    everyone who chose Yearly is billed monthly, or everyone who chose Pro
///    gets Plus. Nothing visible breaks.
/// 2. **The numeric variant id in the path.** It reads like an id and it is the
///    one printed everywhere else — `/checkout/buy/2124315` is a 404, checked
///    against the live store.
/// 3. **A guessed path.** They shipped for months as `/buy/monthly` and
///    `/buy/yearly`, which look entirely plausible and 404 against any real
///    store.
///
/// **And a fourth these tests CANNOT close, stated so nobody reads a green run
/// as more than it is: two uuids being the wrong way round.** Swap them and
/// every assertion here still passes — they stay distinct, well-formed uuids
/// on the right host — while everyone who picks Yearly is offered Monthly, or
/// everyone who picks Pro is offered Plus. Which uuid belongs to which plan
/// is a fact about the Lemon Squeezy dashboard, and the only way to check it
/// is to open each page and read which price is picked.
/// `PlanCatalog.checkoutURL` records when that was last done.
final class CheckoutURLTests: XCTestCase {
    private let paid: [(AirlockPlan, License.Period)] = [
        (.plus, .monthly), (.plus, .yearly), (.pro, .monthly), (.pro, .yearly),
    ]

    private var links: [URL] { paid.compactMap { PlanCatalog.checkoutURL($0.0, $0.1) } }

    func testEveryPaidPlanHasALinkAndFreeHasNone() {
        XCTAssertEqual(links.count, 4)
        XCTAssertNil(PlanCatalog.checkoutURL(.free, .monthly))
        XCTAssertNil(PlanCatalog.checkoutURL(.free, .yearly))
    }

    /// The one that costs money rather than merely failing.
    func testNoTwoPlansShareALink() {
        XCTAssertEqual(Set(links).count, links.count,
                       "one uuid pasted twice bills somebody for the plan they didn't choose, and looks fine")
    }

    func testAllPointAtTheLiveStoreOverHTTPS() {
        for u in links + [PlanCatalog.manageURL] {
            XCTAssertEqual(u.scheme, "https")
            XCTAssertEqual(u.host, "useairlock.lemonsqueezy.com", "\(u)")
        }
    }

    /// `/checkout/buy/<variant uuid>` — not `/buy/<name>`, and not the numeric
    /// id. A uuid is 36 characters with four hyphens.
    func testThePathCarriesAVariantUUID() {
        for u in links {
            XCTAssertTrue(u.path.hasPrefix("/checkout/buy/"), "\(u)")
            let slug = u.lastPathComponent
            XCTAssertNotNil(UUID(uuidString: slug),
                            "\(slug) is not a uuid — a numeric variant id 404s, and so does a guessed name")
        }
    }
}
