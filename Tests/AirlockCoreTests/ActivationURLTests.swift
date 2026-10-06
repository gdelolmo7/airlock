import XCTest
@testable import AirlockCore

/// A URL is the one input that arrives from outside the app, typed by anyone.
///
/// These pin the shape rather than the trust: what comes out is a *candidate*,
/// and whether it is a real licence is `LicenseVerifier`'s question. What must
/// not happen is this accepting a URL it was never meant to handle, or dropping
/// one it was.
final class ActivationURLTests: XCTestCase {
    private func key(_ string: String) -> String? {
        URL(string: string).flatMap(ActivationURL.key(from:))
    }

    func testItReadsTheKey() {
        XCTAssertEqual(key("airlock://activate?key=ABC-123"), "ABC-123")
    }

    /// Schemes are case-insensitive in practice, and a browser is entitled to
    /// hand back whichever case it likes.
    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(key("AIRLOCK://ACTIVATE?key=ABC-123"), "ABC-123")
    }

    /// Strict about the host, deliberately: an app that accepts
    /// `airlock://anything?key=…` cannot tell a second meaning apart later.
    func testAnotherHostIsNotAnActivation() {
        XCTAssertNil(key("airlock://open?key=ABC-123"))
        XCTAssertNil(key("airlock://activate-now?key=ABC-123"))
    }

    func testAnotherSchemeIsRefused() {
        XCTAssertNil(key("https://activate?key=ABC-123"))
        XCTAssertNil(key("airlockx://activate?key=ABC-123"))
    }

    func testAMissingOrEmptyKeyIsNil() {
        XCTAssertNil(key("airlock://activate"))
        XCTAssertNil(key("airlock://activate?key="))
        XCTAssertNil(key("airlock://activate?token=ABC-123"))
    }

    /// Whitespace around a pasted key is the user's, not the format's.
    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(key("airlock://activate?key=%20ABC-123%20"), "ABC-123")
    }

    /// A signed token carries characters a query string has to escape. Losing
    /// any of them turns a good licence into "invalid licence", which is the
    /// hardest failure here to diagnose.
    func testAKeyWithURLUnsafeCharactersSurvivesARoundTrip() {
        let token = "eyJhbGci+OiJF/ZERTQSJ9.abc==?&#x"
        guard let url = ActivationURL.url(key: token) else {
            return XCTFail("could not build the URL")
        }
        XCTAssertEqual(ActivationURL.key(from: url), token)
    }

    func testTheBuiltURLIsTheOneWeParse() {
        let url = ActivationURL.url(key: "ABC-123")
        XCTAssertEqual(url?.scheme, ActivationURL.scheme)
        XCTAssertEqual(url?.host, ActivationURL.host)
    }
}
