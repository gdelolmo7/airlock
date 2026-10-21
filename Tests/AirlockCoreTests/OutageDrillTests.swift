import XCTest
@testable import AirlockCore

/// The pretend outage is a hidden switch on the owner's own Mac. What must
/// never happen is it switching on by itself: without its flag, every
/// service is left as it is.
final class OutageDrillTests: XCTestCase {
    func testNothingWithoutTheFlag() {
        XCTAssertNil(OutageDrill.failure(in: ["Airlock"]))
        XCTAssertNil(OutageDrill.failure(in: ["Airlock", "--state-gallery", "K94"]))
        XCTAssertNil(OutageDrill.failure(in: ["Airlock", "--no-apple-intelligence"]))
        XCTAssertFalse(OutageDrill.hidesAppleIntelligence(in: ["Airlock", "--outage"]))
    }

    func testTheFlagAloneIsNobodyAnswering() {
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage"]), .noReply)
    }

    func testAStatusAfterTheFlagIsTheReply() {
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "503"]), .serverError(503))
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "500"]), .serverError(500))
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "599"]), .serverError(599))
    }

    /// Only a server's own failure: a 404 or a 402 would be the server
    /// answering, and the licence reads a 402 as a plan declined.
    func testAnythingElseAfterTheFlagLeavesItAtNoReply() {
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "404"]), .noReply)
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "402"]), .noReply)
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "600"]), .noReply)
        XCTAssertEqual(OutageDrill.failure(in: ["Airlock", "--outage", "--no-apple-intelligence"]), .noReply)
    }

    func testAppleIntelligenceHiddenOnlyByItsFlag() {
        XCTAssertTrue(OutageDrill.hidesAppleIntelligence(in: ["Airlock", "--outage", "--no-apple-intelligence"]))
        XCTAssertEqual(OutageDrill.availability(.ready, hidden: true), .needsAppleIntelligence)
        XCTAssertEqual(OutageDrill.availability(.ready, hidden: false), .ready)
        XCTAssertEqual(OutageDrill.availability(.modelNotReady, hidden: false), .modelNotReady)
    }

    /// The log says it is pretend, so it is never read as a real outage.
    func testTheLogSaysItIsPretend() {
        XCTAssertTrue(OutageDrill.logLine(.noReply).hasPrefix("pretend outage"))
        XCTAssertTrue(OutageDrill.logLine(.serverError(503)).contains("503"))
    }

    /// Nothing listens on port 9 here, so the update check is refused at
    /// once instead of waiting out a timeout.
    func testTheDeadFeedIsThisMac() {
        let url = URL(string: OutageDrill.deadFeedURL)
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 9)
    }
}
