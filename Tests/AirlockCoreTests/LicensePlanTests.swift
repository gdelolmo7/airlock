import CryptoKit
import XCTest
@testable import AirlockCore

/// Which plan a key says was paid for: Plus or Pro.
///
/// The payloads below are written out by hand, byte for byte the shapes the
/// licence server mints, rather than encoded from a `License`. A test that
/// encodes and decodes with the same type proves the type agrees with itself;
/// these prove the app reads what the server actually sends, including the
/// keys every customer already holds.
final class LicensePlanTests: XCTestCase {
    private let issuer = Curve25519.Signing.PrivateKey()
    private var publicKey: Data { issuer.publicKey.rawRepresentation }

    private func sign(_ payload: String) -> String {
        let bytes = Data(payload.utf8)
        let signature = try! issuer.signature(for: bytes)
        return "\(LicenseVerifier.encode(bytes)).\(LicenseVerifier.encode(signature))"
    }

    private func sign(_ license: License) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try! encoder.encode(license)
        return sign(String(decoding: payload, as: UTF8.self))
    }

    private func verify(_ token: String) -> License? {
        LicenseVerifier.verify(token, publicKey: publicKey).license
    }

    /// The server's payload, with `plan` written in where it goes, or left out
    /// the way every key from before plans has it.
    private func serverPayload(plan: String?) -> String {
        let planField = plan.map { #""plan":"\#($0)","# } ?? ""
        return #"{"checkBy":"2027-10-29T10:00:00Z","email":"someone@example.com","id":"lic_4242","issued":"2026-10-15T18:00:00Z","period":"yearly","#
            + planField
            + #""product":"airlock","ref":"LS-KEY-REF","renewsAt":"2027-10-15T10:00:00Z"}"#
    }

    // MARK: - Keys people already hold

    /// Everybody paying before plans existed holds a key with no plan in it,
    /// and every one of them bought what is now Plus. Nobody has to do anything.
    func testAKeyFromBeforePlansIsPlus() {
        let license = verify(sign(serverPayload(plan: nil)))
        XCTAssertNotNil(license, "a key from before plans must still verify")
        XCTAssertEqual(license?.plan, .plus)
        XCTAssertEqual(license?.id, "lic_4242")
    }

    // MARK: - Keys the server mints now

    func testAPlusPurchaseReadsAsPlus() {
        XCTAssertEqual(verify(sign(serverPayload(plan: "plus")))?.plan, .plus)
    }

    func testAProPurchaseReadsAsPro() {
        XCTAssertEqual(verify(sign(serverPayload(plan: "pro")))?.plan, .pro)
    }

    /// A plan added after this build shipped must not break a paid key: it
    /// reads as Plus, the floor for anybody who paid, until the app is updated.
    func testAPlanThisBuildDoesNotKnowIsPlusNotABrokenKey() {
        let license = verify(sign(serverPayload(plan: "team")))
        XCTAssertNotNil(license, "an unknown plan must never make a genuine key invalid")
        XCTAssertEqual(license?.plan, .plus)
    }

    /// The plan is inside the signature like everything else: editing a Plus
    /// key to say Pro is a forgery, refused as one.
    func testEditingThePlanBreaksTheSignature() {
        let genuine = sign(serverPayload(plan: "plus"))
        let signature = genuine.split(separator: ".")[1]
        let edited = Data(serverPayload(plan: "pro").utf8)
        let forged = "\(LicenseVerifier.encode(edited)).\(signature)"

        XCTAssertEqual(LicenseVerifier.verify(forged, publicKey: publicKey), .invalid(.signature))
    }

    // MARK: - Keys made by hand (LicenseTool)

    /// A hand-made key that names no plan is Plus, and says so in the key
    /// rather than leaving it out.
    func testAHandMadeKeyIsPlusUnlessItNamesAPlan() {
        let handMade = License(id: "lic_hand", email: "friend@example.com", product: "airlock",
                               period: .yearly, issued: Date(timeIntervalSince1970: 1_800_000_000),
                               renewsAt: Date(timeIntervalSince1970: 1_831_536_000),
                               checkBy: Date(timeIntervalSince1970: 1_832_745_600))
        XCTAssertEqual(handMade.plan, .plus)

        let token = sign(handMade)
        XCTAssertTrue(payload(of: token).contains(#""plan":"plus""#))
        XCTAssertEqual(verify(token), handMade)
    }

    func testAHandMadeProKeyReadsAsPro() {
        let handMade = License(id: "lic_handpro", email: "friend@example.com", product: "airlock",
                               period: .yearly, issued: Date(timeIntervalSince1970: 1_800_000_000),
                               renewsAt: Date(timeIntervalSince1970: 1_831_536_000),
                               checkBy: Date(timeIntervalSince1970: 1_832_745_600), plan: .pro)
        XCTAssertEqual(verify(sign(handMade))?.plan, .pro)
    }

    /// LicenseTool's sorted keys put `plan` between `period` and `product`,
    /// which is where the licence server writes it, so a hand-made key and a
    /// server-made one with the same fields are the same bytes.
    func testAHandMadeKeyWritesThePlanWhereTheServerDoes() {
        let handMade = License(id: "lic_4242", email: "someone@example.com", product: "airlock",
                               period: .yearly,
                               issued: ISO8601DateFormatter().date(from: "2026-10-15T18:00:00Z")!,
                               renewsAt: ISO8601DateFormatter().date(from: "2027-10-15T10:00:00Z")!,
                               checkBy: ISO8601DateFormatter().date(from: "2027-10-29T10:00:00Z")!,
                               ref: "LS-KEY-REF", plan: .pro)
        XCTAssertEqual(payload(of: sign(handMade)), serverPayload(plan: "pro"))
    }

    // MARK: - Labels

    func testThePlansAreNamedForPeople() {
        XCTAssertEqual(License.Plan.plus.label, "Plus")
        XCTAssertEqual(License.Plan.pro.label, "Pro")
    }

    private func payload(of token: String) -> String {
        var text = String(token.split(separator: ".")[0])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return String(decoding: Data(base64Encoded: text)!, as: UTF8.self)
    }
}
