import XCTest
import AirlockCore
@testable import AirlockApp

/// Where the cloud stands in for an icon, and where it must not. The places
/// that are views and nothing else need no test; these two are choices made
/// per case, and the case lists grow. A new dictation notice or setup page
/// should arrive without a face, and get one only by somebody deciding it.
@MainActor
final class BloubPlacementTests: XCTestCase {
    /// Only "heard nothing" is about the cloud itself. The rest are about the
    /// Mac, a permission or where the words went, and keep their glyph. (A
    /// hold turned away after the trial wore the cloud too, until nothing
    /// locked any more.)
    func testOnlyHeardNothingGetsAFace() {
        XCTAssertEqual(HoldNoticeCard.face(for: .nothingCaught(key: "⌃ Control")), .confused)

        let others: [DictationHoldNotice] = [
            .microphoneDenied,
            .noSpeechModel(locale: "en_US"),
            .notBundled,
            .microphoneFailedToStart,
            .microphoneAllowed(key: "⌃ Control", asking: false),
            .copiedNowhereToType,
            .copiedAfterKeyOrClick,
            .reachedLimit,
            .tidyingFailed,
            .secureInput(holder: nil),
        ]
        for notice in others {
            XCTAssertNil(HoldNoticeCard.face(for: notice), "\(notice) should keep its glyph")
        }
    }

    /// "You're on Free now" is good news told plainly: the cloud awake and
    /// calm, in the working blue, not the resting grey and not the stressed
    /// face kept for a limit reached.
    func testTheFreeCardWearsACalmAwakeCloud() {
        XCTAssertEqual(MovedToFreeCard.face, .neutral)
        XCTAssertNotEqual(MovedToFreeCard.face, .stressed, "nothing is wrong")
        XCTAssertNotEqual(MovedToFreeCard.face, .sleepy)
        XCTAssertNotEqual(MovedToFreeCard.tint, .resting, "a real Bloub colour, not grey")
        XCTAssertTrue((44...60).contains(MovedToFreeCard.cloudWidth),
                      "\(MovedToFreeCard.cloudWidth)pt is a card's cloud, not a page's")
    }

    /// The pages that open and close setup, and nothing between them.
    func testOnlyTheFirstAndLastSetupPagesGetAFace() {
        XCTAssertEqual(PanelOnboardingView.face(for: .welcome), .excited)
        XCTAssertEqual(PanelOnboardingView.face(for: .finish), .proud)
        let between = OnboardingPlan.Step.allCases.filter { $0 != .welcome && $0 != .finish }
        XCTAssertFalse(between.isEmpty)
        for step in between {
            XCTAssertNil(PanelOnboardingView.face(for: step), "\(step) is a list of things to do")
        }
    }
}
