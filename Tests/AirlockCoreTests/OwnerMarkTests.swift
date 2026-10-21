import Foundation
import XCTest
@testable import AirlockCore

/// The owner's link and mark (`OwnerMark`): what is read out of a link,
/// what counts as a mark, and what the app asks before keeping one.
final class OwnerMarkTests: XCTestCase {
    private let mark = "0123456789abcdef0123456789abcdef"

    func testTheOwnerLinkCarriesItsMark() {
        let url = URL(string: "airlock://this-mac-is-mine?mark=\(mark)")!
        XCTAssertEqual(OwnerMark.mark(from: url), mark)
    }

    func testCapitalsAreTheSameMark() {
        let url = URL(string: "AIRLOCK://This-Mac-Is-Mine?mark=\(mark.uppercased())")!
        XCTAssertEqual(OwnerMark.mark(from: url), mark)
    }

    func testAnythingElseIsNoMark() {
        let links = [
            "airlock://activate?key=\(mark)",
            "airlock://this-mac-is-mine",
            "airlock://this-mac-is-mine?key=\(mark)",
            "airlock://this-mac-is-mine?mark=",
            "airlock://this-mac-is-mine?mark=\(mark.dropLast())",
            "airlock://this-mac-is-mine?mark=\(mark)0",
            "airlock://this-mac-is-mine?mark=\(mark.dropLast())g",
            "https://this-mac-is-mine?mark=\(mark)",
            "airlock://somewhere-else?mark=\(mark)",
        ]
        for link in links {
            XCTAssertNil(OwnerMark.mark(from: URL(string: link)!), link)
        }
    }

    func testAMarkIsThirtyTwoPlainHexDigits() {
        XCTAssertEqual(OwnerMark.valid("  \(mark)\n"), mark)
        XCTAssertNil(OwnerMark.valid(""))
        XCTAssertNil(OwnerMark.valid("lic_2e8a0d03"))
        XCTAssertNil(OwnerMark.valid(UUID().uuidString))
        // Full-width digits are hex digits to Swift, never a mark.
        XCTAssertNil(OwnerMark.valid(String(mark.dropLast()) + "\u{FF11}"))
    }

    func testANewMarkIsAskedAbout() {
        let question = OwnerMark.question(new: mark, current: nil, sendsCounts: true)
        XCTAssertEqual(question.title, "Mark this Mac as yours?")
        XCTAssertEqual(question.keep, "Mark as Mine")
        XCTAssertEqual(question.done, "Cancel")
        XCTAssertTrue(question.message.contains("Hide me"))
        XCTAssertFalse(question.message.contains("off on this Mac"))
        XCTAssertFalse(question.message.contains("replaces"))
    }

    func testTheQuestionSaysWhenCountsAreOff() {
        let question = OwnerMark.question(new: mark, current: nil, sendsCounts: false)
        XCTAssertTrue(question.message.contains("Usage counts are off on this Mac"))
    }

    func testTheQuestionSaysWhenItReplacesAMark() {
        let question = OwnerMark.question(new: mark, current: String(repeating: "a", count: 32), sendsCounts: true)
        XCTAssertNotNil(question.keep)
        XCTAssertTrue(question.message.contains("replaces the mark this Mac has now"))
    }

    func testTheSameMarkAgainIsOnlyANotice() {
        let question = OwnerMark.question(new: mark, current: mark, sendsCounts: true)
        XCTAssertEqual(question.title, "This Mac is already marked as yours")
        XCTAssertNil(question.keep)
        XCTAssertEqual(question.done, "OK")
    }

    func testTheMarkGoesInTheBodyOnlyWhenThereIsOne() throws {
        let context = UsageContext(app: "1.0.26", build: "1050", os: "26.1", model: "Mac16,1",
                                   language: "es", plan: .pro)
        let records = [UsageRecord(.appOpened, at: Date(timeIntervalSince1970: 1_800_000_000))]
        func owner(_ value: String?) throws -> Any? {
            let data = try UsageWire.body(install: "install-id", context: context, records: records, owner: value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return object["owner"]
        }
        XCTAssertEqual(try owner(mark) as? String, mark)
        XCTAssertEqual(try owner(mark.uppercased()) as? String, mark)
        XCTAssertNil(try owner(nil))
        XCTAssertNil(try owner("not a mark"), "a malformed mark is left out rather than refused")
    }
}
