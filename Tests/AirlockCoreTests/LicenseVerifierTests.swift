import CryptoKit
import XCTest
@testable import AirlockCore

final class LicenseVerifierTests: XCTestCase {
    private let issuer = Curve25519.Signing.PrivateKey()
    private var publicKey: Data { issuer.publicKey.rawRepresentation }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Signs a licence the way the vendor would, so the tests exercise the real
    /// round trip rather than a stub.
    private func token(_ license: License,
                       signedBy key: Curve25519.Signing.PrivateKey? = nil) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try! encoder.encode(license)
        let signature = try! (key ?? issuer).signature(for: payload)
        return "\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))"
    }

    private func license(product: String = "airlock",
                         renewsIn days: Double = 30) -> License {
        let renews = now.addingTimeInterval(days * 86_400)
        return License(id: "lic_123", email: "someone@example.com", product: product,
                       period: .monthly, issued: now.addingTimeInterval(-86_400),
                       renewsAt: renews,
                       checkBy: renews.addingTimeInterval(14 * 86_400))
    }

    // MARK: - The happy path

    func testAGenuineLicenceSurvivesTheRoundTrip() {
        let original = license()
        let verdict = LicenseVerifier.verify(token(original), publicKey: publicKey)
        XCTAssertEqual(verdict, .valid(original))
        XCTAssertEqual(verdict.license?.email, "someone@example.com")
    }

    func testWhitespaceAroundAPastedKeyIsForgiven() {
        let padded = "\n  \(token(license()))  \n"
        XCTAssertEqual(LicenseVerifier.verify(padded, publicKey: publicKey), .valid(license()))
    }

    /// Every field has to survive intact — a licence that comes back with the
    /// wrong dates would be worse than one that failed outright.
    func testEveryFieldSurvivesEncodingAndDecoding() {
        let original = license(renewsIn: 365)
        guard case .valid(let decoded) = LicenseVerifier.verify(token(original),
                                                                publicKey: publicKey) else {
            return XCTFail("should have verified")
        }
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.email, original.email)
        XCTAssertEqual(decoded.period, original.period)
        XCTAssertEqual(decoded.renewsAt.timeIntervalSince1970,
                       original.renewsAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.checkBy.timeIntervalSince1970,
                       original.checkBy.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Authenticity is all this decides

    /// A long-expired licence still VERIFIES. Whether it entitles anyone to
    /// anything is `Entitlement`'s question, asked against two dates this type
    /// deliberately does not read — and a key that reported itself invalid
    /// merely for being old could never be renewed in place.
    func testAnOutOfDateLicenceIsStillGenuine() {
        let ancient = license(renewsIn: -900)
        XCTAssertEqual(LicenseVerifier.verify(token(ancient), publicKey: publicKey),
                       .valid(ancient))
    }

    // MARK: - Forgery

    /// THE test. Editing any byte of the payload — the email, the dates, the
    /// product — invalidates the signature, which is the entire basis for
    /// trusting a file the customer holds.
    func testAnEditedPayloadIsRejected() {
        let genuine = token(license())
        let parts = genuine.split(separator: ".")
        // Re-encode the payload with a renewal date centuries out, keeping the
        // real signature. This is the obvious attack and it must not work.
        let forged = License(id: "lic_123", email: "someone@example.com",
                             product: "airlock", period: .monthly, issued: now,
                             renewsAt: now.addingTimeInterval(999_999_999),
                             checkBy: now.addingTimeInterval(999_999_999))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let tampered = LicenseVerifier.encode(try! encoder.encode(forged)) + "." + parts[1]

        XCTAssertEqual(LicenseVerifier.verify(tampered, publicKey: publicKey),
                       .invalid(.signature))
    }

    /// Signed perfectly — by somebody else. This is what a home-made key
    /// generator produces, and it must not work.
    func testALicenceSignedByAnotherKeyIsRejected() {
        let impostor = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(LicenseVerifier.verify(token(license(), signedBy: impostor),
                                              publicKey: publicKey),
                       .invalid(.signature))
    }

    /// A licence for another product the same key signs must not unlock this one.
    func testALicenceForAnotherProductIsRejected() {
        XCTAssertEqual(LicenseVerifier.verify(token(license(product: "something-else")),
                                              publicKey: publicKey),
                       .invalid(.wrongProduct))
    }

    // MARK: - Rubbish in

    func testMalformedInputIsRejectedWithoutCrashing() {
        for junk in ["", ".", "..", "not-a-licence", "a.b", "!!!.???",
                     String(repeating: "A", count: 10_000)] {
            XCTAssertNil(LicenseVerifier.verify(junk, publicKey: publicKey).license,
                         junk.prefix(20).description)
        }
    }

    func testValidSignatureOverNonJSONIsMalformed() {
        let payload = Data("this is signed, but it is not a licence".utf8)
        let signature = try! issuer.signature(for: payload)
        let token = "\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))"
        XCTAssertEqual(LicenseVerifier.verify(token, publicKey: publicKey),
                       .invalid(.malformed))
    }

    /// A garbage public key must fail closed rather than throw.
    func testAnUnusablePublicKeyRejectsEverything() {
        XCTAssertEqual(LicenseVerifier.verify(token(license()), publicKey: Data([1, 2, 3])),
                       .invalid(.signature))
    }
}
