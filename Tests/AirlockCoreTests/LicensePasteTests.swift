import XCTest
@testable import AirlockCore

/// Which way a pasted licence goes, and who a refusal is about (card B5).
final class LicensePasteTests: XCTestCase {
    private let license = License(id: "lic_1", email: "a@b.com", product: "airlock", period: .yearly,
                                  issued: Date(timeIntervalSince1970: 1_800_000_000),
                                  renewsAt: Date(timeIntervalSince1970: 1_830_000_000),
                                  checkBy: Date(timeIntervalSince1970: 1_831_000_000))

    func testASignedLicenceIsKept() {
        XCTAssertEqual(LicensePaste.step(verdict: .valid(license), hasServer: true), .store)
        // The offline path works with no server at all — that is the point of it.
        XCTAssertEqual(LicensePaste.step(verdict: .valid(license), hasServer: false), .store)
    }

    /// The shop's key is not a signed licence, so it reads as malformed here
    /// and only the server can judge it.
    func testTheShopsKeyGoesToTheServer() {
        XCTAssertEqual(LicensePaste.step(verdict: .invalid(.malformed), hasServer: true), .askServer)
    }

    /// A build packaged without its public key or its server address must
    /// never answer as if the customer had pasted the wrong thing.
    func testABuildThatCannotCheckSaysSo() {
        XCTAssertEqual(LicensePaste.step(verdict: nil, hasServer: true), .cannotCheck)
        XCTAssertEqual(LicensePaste.step(verdict: nil, hasServer: false), .cannotCheck)
        XCTAssertEqual(LicensePaste.step(verdict: .invalid(.malformed), hasServer: false), .cannotCheck)
    }

    /// A signed licence that can't be used here is named for what it is — the
    /// server would only call it "not a licence key".
    func testASignedLicenceThatCantBeUsedHereIsNamed() {
        for reason: LicenseVerdict.Reason in [.otherMachine, .signature, .wrongProduct] {
            XCTAssertEqual(LicensePaste.step(verdict: .invalid(reason), hasServer: true), .refuse(reason))
            XCTAssertEqual(LicensePaste.step(verdict: .invalid(reason), hasServer: false), .refuse(reason))
        }
    }
}
