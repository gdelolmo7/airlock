import XCTest
@testable import AirlockCore

/// Entries are copied from `IOPMCopyAssertionsByProcess` on the owner's Mac,
/// 2026-10-26, with YouTube playing in Chrome (pid 693).
final class VideoInFrontTests: XCTestCase {
    private let chromeVideo: [String: Any] = [
        "AssertPID": 693, "AssertName": "Video Wake Lock",
        "AssertType": "NoDisplaySleepAssertion", "AssertionTrueType": "PreventUserIdleDisplaySleep",
    ]
    private let chromeAudio: [String: Any] = [
        "AssertPID": 693, "AssertName": "Playing audio",
        "AssertType": "NoIdleSleepAssertion", "AssertionTrueType": "PreventUserIdleSystemSleep",
    ]
    private let powerd: [String: Any] = [
        "AssertPID": 348, "AssertType": "InternalPreventDisplaySleep",
        "AssertionTrueType": "InternalPreventDisplaySleep",
    ]

    private func locks(_ entries: [[String: Any]]) -> [VideoInFront.ScreenLock] {
        entries.compactMap(VideoInFront.lock(from:))
    }

    func testAVideoPlayingInTheFrontAppCounts() {
        XCTAssertTrue(VideoInFront.isPlaying(front: 693, locks: locks([chromeAudio, chromeVideo, powerd])))
    }

    func testMusicAloneIsNotAVideo() {
        XCTAssertFalse(VideoInFront.isPlaying(front: 693, locks: locks([chromeAudio, powerd])),
                       "keeping the Mac awake is not keeping the screen on")
    }

    func testAnotherAppsVideoDoesNotCount() {
        XCTAssertFalse(VideoInFront.isPlaying(front: 412, locks: locks([chromeVideo])),
                       "a full-screen editor in front of a browser playing a video keeps the island")
    }

    func testMacOSsOwnDisplayLockDoesNotCount() {
        XCTAssertFalse(VideoInFront.isPlaying(front: 348, locks: locks([powerd])))
    }

    func testALockHeldOnTheFrontAppsBehalfCounts() {
        let helper: [String: Any] = ["AssertPID": 901, "AssertionOnBehalfOfPID": 412,
                                     "AssertType": "PreventUserIdleDisplaySleep"]
        XCTAssertTrue(VideoInFront.isPlaying(front: 412, locks: locks([helper])))
    }

    func testAnEntryNamingNoProcessIsSkipped() {
        XCTAssertNil(VideoInFront.lock(from: ["AssertType": "PreventUserIdleDisplaySleep"]))
    }
}
