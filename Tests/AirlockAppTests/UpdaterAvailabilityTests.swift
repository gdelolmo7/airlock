import XCTest
@testable import AirlockApp

/// Whether the Updates section is offered at all.
///
/// **The bug this pins shipped in the 1.0 candidate.** `isAvailable` asked only
/// whether the app was in a `.app` bundle, while the Settings view guarding on
/// it carried a comment saying packaging "leaves the updater out entirely when
/// there is no appcast URL or signing key" — so a release built without Sparkle
/// keys produced a bundle, passed the check, and drew a full Updates section
/// with a Check Now that could only fail, above a paragraph promising signature
/// verification that had never been configured.
///
/// Verified against the packaged build at the time: no `SUFeedURL`, no
/// `SUPublicEDKey`, and the section rendered anyway.
final class UpdaterAvailabilityTests: XCTestCase {

    private func usable(bundled: Bool = true, feed: Any? = "https://x/appcast.xml", key: Any? = "abc") -> Bool {
        UpdaterModel.updaterIsUsable(isBundled: bundled, feedURL: feed, publicKey: key)
    }

    func testAConfiguredBundleCanUpdate() {
        XCTAssertTrue(usable())
    }

    /// `swift run` — nothing to update, and the original reason for the check.
    func testAnUnbundledBuildCannotUpdate() {
        XCTAssertFalse(usable(bundled: false))
    }

    /// The case that shipped. A real bundle, and nowhere to ask.
    func testABundleWithNoFeedCannotUpdate() {
        XCTAssertFalse(usable(feed: nil), "a bundle without SUFeedURL has no appcast to check")
    }

    /// Trust is the signature, not the download — without the key, anything that
    /// came back would be unverifiable, so offering the check is worse than not.
    func testABundleWithNoSigningKeyCannotUpdate() {
        XCTAssertFalse(usable(key: nil))
    }

    func testEveryPieceIsRequired() {
        XCTAssertFalse(usable(bundled: false, feed: nil, key: nil))
    }
}
