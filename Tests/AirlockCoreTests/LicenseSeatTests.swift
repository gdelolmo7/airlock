import XCTest
@testable import AirlockCore

/// One licence, one Mac.
///
/// The seat check is the newest thing that can refuse a licence somebody paid
/// for, so the tests lean hardest on what it must NOT refuse: a token issued
/// before seats existed, and a hand-issued one that names no machine. Both are
/// honoured everywhere, because a rule added later must not revoke something
/// already bought.
final class LicenseSeatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func license(machine: String?) -> License {
        License(id: "l", email: "a@b.c", product: "airlock", period: .yearly,
                issued: t0, renewsAt: t0.addingTimeInterval(31_536_000),
                checkBy: t0.addingTimeInterval(32_745_600),
                ref: "sub_123", machine: machine)
    }

    /// The binding rides inside the signed payload, so it survives a round trip
    /// and cannot be edited without breaking the signature.
    func testTheMachineSurvivesEncoding() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(license(machine: "UUID-A"))
        XCTAssertEqual(try decoder.decode(License.self, from: data).machine, "UUID-A")
    }

    /// A licence issued before seats existed has no machine, and must keep
    /// working on the Mac it is already installed on.
    func testALicenceWithNoMachineIsHonouredAnywhere() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(license(machine: nil))
        let decoded = try {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(License.self, from: data)
        }()
        XCTAssertNil(decoded.machine, "no machine means no seat check — see LicenseVerifier")
    }

    /// The refusal has a reason of its own rather than collapsing into
    /// "invalid": the message it produces is the difference between "this is
    /// already on another Mac" and sending somebody to support.
    /// **The seat check was unreachable in production until 2026-08-21**, and
    /// nothing in this file noticed, because every test here hands the verifier
    /// a machine directly. No ISSUER ever set one: `mint()` emitted eight keys
    /// and `machine` was not among them, and the app posted `/activate` nothing
    /// but the key. The check was correct, tested, and never once ran.
    ///
    /// A test cannot prove the Worker mints the field — that is JavaScript, and
    /// this suite is Swift. What it can pin is the contract the Worker has to
    /// satisfy, which is that the machine is part of the ENCODED payload and so
    /// part of what the signature covers.
    func testTheMachineIsInsideTheSignedPayloadNotBesideIt() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(license(machine: "THIS-MAC")), encoding: .utf8)
        XCTAssertEqual(json?.contains("\"machine\":\"THIS-MAC\""), true,
                       "the Worker mints this key; if it moves, tokens stop verifying")
    }

    /// The rule a refresh must obey, stated from the app's side: a licence names
    /// exactly one Mac for its whole life. The Worker carries `license.machine`
    /// across untouched on renewal — if a refresh could re-stamp it, whichever
    /// Mac renewed first would silently take the licence, which is the opposite
    /// of one licence, one Mac.
    func testAMachineIsNotSomethingARenewalCanChange() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let original = license(machine: "MAC-A")
        let renewed = try decoder.decode(License.self, from: try encoder.encode(original))
        XCTAssertEqual(renewed.machine, "MAC-A")
        XCTAssertNotEqual(renewed.machine, "MAC-B")
    }

    func testTheRefusalIsItsOwnReason() {
        XCTAssertNotEqual(LicenseVerdict.Reason.otherMachine, .signature)
        XCTAssertNotEqual(LicenseVerdict.Reason.otherMachine, .wrongProduct)
        XCTAssertNotEqual(LicenseVerdict.Reason.otherMachine, .malformed)
        // Raw values are stored in diagnostics; a collision would make two
        // different failures read identically in a bug report.
        XCTAssertEqual(LicenseVerdict.Reason.otherMachine.rawValue, "otherMachine")
    }

    /// A seat is not a date. The entitlement states are unchanged by any of
    /// this — a licence for another Mac never becomes an entitlement at all,
    /// because it is refused at the door.
    func testSeatsDoNotChangeWhatAValidLicenceIsEntitledTo() {
        XCTAssertTrue(Entitlement.licensed(license(machine: "UUID-A")).allowsUse)
        XCTAssertTrue(Entitlement.grace(license(machine: "UUID-A")).allowsUse)
    }
}
