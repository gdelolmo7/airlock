import XCTest
@testable import AirlockCore

final class CallStartCheckTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_468_600)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func look(_ check: inout CallStartCheck, mic: Bool = false, micRefused: Bool = false,
                      theirs: Bool = false, notAllowed: Bool = false, lastRefused: Bool = false,
                      _ seconds: TimeInterval) {
        check.update(micHeard: mic, micRefused: micRefused, theirsHeard: theirs,
                     theirsNotAllowed: notAllowed, lastCallRefused: lastRefused, now: at(seconds))
    }

    func testBothHeardShowsTicksForFiveSecondsThenGoes() {
        var check = CallStartCheck()
        look(&check, 0)
        XCTAssertEqual(check.you, .waiting)
        XCTAssertEqual(check.them, .waiting)
        XCTAssertTrue(check.isShowing)
        look(&check, mic: true, theirs: true, 2)
        XCTAssertEqual(check.you, .heard)
        XCTAssertEqual(check.them, .heard)
        look(&check, mic: true, theirs: true, 6.9)
        XCTAssertTrue(check.isShowing, "under five seconds of ticks")
        look(&check, mic: true, theirs: true, 7)
        XCTAssertFalse(check.isShowing)
    }

    func testOnceGoneWaitingNeverBringsItBack() {
        var check = CallStartCheck()
        look(&check, mic: true, theirs: true, 0)
        look(&check, mic: true, theirs: true, 5)
        look(&check, 8)
        XCTAssertFalse(check.isShowing)
    }

    func testNothingHeardGivesUpQuietlyAfterThirtySeconds() {
        var check = CallStartCheck()
        look(&check, mic: true, 0)
        look(&check, mic: true, 29.9)
        XCTAssertTrue(check.isShowing)
        look(&check, mic: true, 30)
        XCTAssertFalse(check.isShowing)
    }

    func testARefusalStaysPastBothLimits() {
        var check = CallStartCheck()
        look(&check, mic: true, notAllowed: true, 0)
        look(&check, mic: true, notAllowed: true, 120)
        XCTAssertEqual(check.them, .refused)
        XCTAssertTrue(check.isShowing)
    }

    func testALateRefusalBringsItBack() {
        var check = CallStartCheck()
        look(&check, mic: true, 0)
        look(&check, mic: true, 31)
        XCTAssertFalse(check.isShowing)
        look(&check, mic: true, notAllowed: true, 45)
        XCTAssertTrue(check.isShowing)
        XCTAssertEqual(check.them, .refused)
    }

    func testLastCallRefusedIsSaidAtOnceUntilSoundArrives() {
        var check = CallStartCheck()
        look(&check, mic: true, lastRefused: true, 0)
        XCTAssertEqual(check.them, .refused)
        look(&check, mic: true, theirs: true, lastRefused: true, 10)
        XCTAssertEqual(check.them, .heard, "this call's sound outranks the memory")
        look(&check, mic: true, theirs: true, lastRefused: true, 15)
        XCTAssertFalse(check.isShowing)
    }

    func testARefusedMicrophoneIsYours() {
        var check = CallStartCheck()
        look(&check, micRefused: true, theirs: true, 0)
        XCTAssertEqual(check.you, .refused)
        XCTAssertTrue(check.hasRefusal)
        look(&check, micRefused: true, theirs: true, 60)
        XCTAssertTrue(check.isShowing)
    }

    func testInTheRoomOnlyYouCount() {
        var check = CallStartCheck(inPerson: true)
        look(&check, mic: true, notAllowed: true, lastRefused: true, 0)
        XCTAssertNil(check.them)
        XCTAssertFalse(check.hasRefusal)
        look(&check, mic: true, 5)
        XCTAssertFalse(check.isShowing)
    }

    func testHistoryRoundTripsAndStartsEmpty() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CallStartCheckTests"))
        defaults.removePersistentDomain(forName: "CallStartCheckTests")
        XCTAssertNil(OtherSideHistory.read(defaults))
        OtherSideHistory.refused.save(defaults)
        XCTAssertEqual(OtherSideHistory.read(defaults), .refused)
        OtherSideHistory.worked.save(defaults)
        XCTAssertEqual(OtherSideHistory.read(defaults), .worked)
        defaults.removePersistentDomain(forName: "CallStartCheckTests")
    }
}
