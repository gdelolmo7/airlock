import XCTest
import AirlockCore
@testable import AirlockApp

/// The two links that take money.
///
/// Nothing guarded these until the store went live, and they are the easiest
/// thing in the app to get quietly wrong. Three ways, each of which these tests
/// close:
///
/// 1. **The same uuid pasted twice.** Both buttons then work, both charge, and
///    everyone who chose Yearly is billed monthly. Nothing visible breaks.
/// 2. **The numeric variant id in the path.** It reads like an id and it is the
///    one printed everywhere else — `/checkout/buy/2124315` is a 404, checked
///    against the live store.
/// 3. **A guessed path.** They shipped for months as `/buy/monthly` and
///    `/buy/yearly`, which look entirely plausible and 404 against any real
///    store.
///
/// **And a fourth these tests CANNOT close, stated so nobody reads a green run
/// as more than it is: the two uuids being the wrong way round.** Swap them and
/// every assertion here still passes — they stay two distinct, well-formed
/// uuids on the right host — while everyone who picks Annual is offered Monthly
/// and everyone who picks Monthly is offered Annual. Which uuid belongs to which
/// plan is a fact about the Lemon Squeezy dashboard, and the only way to check
/// it is to open both pages and read which radio is filled. Verified by hand
/// 2026-09-15; `LicenseModel.checkoutURL` records what was seen.
@MainActor
final class CheckoutURLTests: XCTestCase {

    private func url(_ period: License.Period) -> URL? {
        LicenseModel.checkoutURL(for: period)
    }

    func testBothPlansHaveALink() {
        XCTAssertNotNil(url(.monthly))
        XCTAssertNotNil(url(.yearly))
    }

    /// The one that costs money rather than merely failing.
    func testThePlansDoNotShareALink() {
        XCTAssertNotEqual(url(.monthly), url(.yearly),
                          "one uuid pasted twice bills yearly buyers monthly, and looks fine")
    }

    func testBothPointAtTheLiveStoreOverHTTPS() {
        for u in [url(.monthly), url(.yearly)].compactMap({ $0 }) {
            XCTAssertEqual(u.scheme, "https")
            XCTAssertEqual(u.host, "useairlock.lemonsqueezy.com", "\(u)")
        }
    }

    /// `/checkout/buy/<variant uuid>` — not `/buy/<name>`, and not the numeric
    /// id. A uuid is 36 characters with four hyphens.
    func testThePathCarriesAVariantUUID() {
        for u in [url(.monthly), url(.yearly)].compactMap({ $0 }) {
            XCTAssertTrue(u.path.hasPrefix("/checkout/buy/"), "\(u)")
            let slug = u.lastPathComponent
            XCTAssertNotNil(UUID(uuidString: slug),
                            "\(slug) is not a uuid — a numeric variant id 404s, and so does a guessed name")
        }
    }
}
