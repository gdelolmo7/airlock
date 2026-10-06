import XCTest
@testable import AirlockCore

/// The quiet half of updating: what Settings says when no Sparkle window is up.
final class UpdateStatusTests: XCTestCase {
    func testANormalCycleOrNothingNewSaysNothing() {
        XCTAssertEqual(UpdateStatus.after(errorCode: nil, previous: .lastCheckFailed), .quiet)
        XCTAssertEqual(UpdateStatus.after(errorCode: 1001, previous: .quiet), .quiet)
        XCTAssertNil(UpdateStatus.line(.quiet, canCheck: true))
    }

    /// "Not now" on the install prompt is a choice, not a failure.
    func testDecliningTheInstallIsNotAFailure() {
        XCTAssertEqual(UpdateStatus.after(errorCode: 4007, previous: .quiet), .quiet)
        XCTAssertEqual(UpdateStatus.after(errorCode: 4008, previous: .quiet), .quiet)
    }

    func testAnythingElseIsACheckThatDidNotGetThrough() {
        XCTAssertEqual(UpdateStatus.after(errorCode: 1002, previous: .quiet), .lastCheckFailed)
        XCTAssertEqual(UpdateStatus.after(errorCode: 2001, previous: .quiet), .lastCheckFailed)
        XCTAssertEqual(UpdateStatus.line(.lastCheckFailed, canCheck: true),
                       "The last check didn't get through. Airlock tries again on its own.")
    }

    func testRunningFromTheDiskImageSaysWhereToPutIt() {
        XCTAssertEqual(UpdateStatus.after(errorCode: 1003, previous: .quiet), .needsMoving)
        XCTAssertEqual(UpdateStatus.after(errorCode: 1005, previous: .quiet), .needsMoving)
    }

    /// A downloaded update stays the news until the app quits.
    func testADownloadedUpdateOutlivesLaterCycles() {
        let ready = UpdateStatus.readyOnQuit(version: "1.4")
        XCTAssertEqual(UpdateStatus.after(errorCode: nil, previous: ready), ready)
        XCTAssertEqual(UpdateStatus.after(errorCode: 1002, previous: ready), ready)
        XCTAssertEqual(UpdateStatus.line(ready, canCheck: true),
                       "Airlock 1.4 is downloaded and installs when you quit Airlock.")
    }

    /// The row this exists for: Check Now greyed out, and now a reason beside it.
    func testAGreyedCheckNowAlwaysHasAReason() {
        let all: [UpdateStatus] = [.quiet, .lastCheckFailed, .needsMoving,
                                   .readyOnQuit(version: ""), .didNotStart]
        for status in all {
            XCTAssertNotNil(UpdateStatus.line(status, canCheck: false), "\(status)")
        }
        XCTAssertEqual(UpdateStatus.line(.quiet, canCheck: false), "Checking for updates…")
    }

    func testPlainWordsOnly() {
        let all: [UpdateStatus] = [.lastCheckFailed, .needsMoving, .readyOnQuit(version: "2.0"), .didNotStart]
        for status in all {
            let line = UpdateStatus.line(status, canCheck: true) ?? ""
            for word in ["Sparkle", "appcast", "error", "XML", "feed"] {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(word), "\(status): \(line)")
            }
        }
    }
}
