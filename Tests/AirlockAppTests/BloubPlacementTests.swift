import XCTest
import AirlockCore
@testable import AirlockApp

/// Where the cloud stands in for an icon, and where it must not. The places
/// that are views and nothing else need no test; these two are choices made
/// per case, and the case lists grow. A new dictation notice or setup page
/// should arrive without a face, and get one only by somebody deciding it.
@MainActor
final class BloubPlacementTests: XCTestCase {
    /// Only "heard nothing" and "the trial has ended" are about the cloud
    /// itself. The rest are about the Mac, a permission or where the words
    /// went, and keep their glyph.
    func testOnlyHeardNothingAndTrialEndedNoticesGetAFace() {
        XCTAssertEqual(HoldNoticeCard.face(for: .nothingCaught), .confused)
        XCTAssertNotNil(HoldNoticeCard.face(for: .noSubscription),
                        "a hold turned away after the trial shows the cloud, not a clock")

        let others: [DictationHoldNotice] = [
            .microphoneDenied,
            .noSpeechModel(locale: "en_US"),
            .notBundled,
            .microphoneFailedToStart,
            .microphoneAllowed(key: "⌃ Control", asking: false),
            .copiedNowhereToType,
            .reachedLimit,
            .tidyingFailed,
            .secureInput(holder: nil),
        ]
        for notice in others {
            XCTAssertNil(HoldNoticeCard.face(for: notice), "\(notice) should keep its glyph")
        }
    }

    /// The trial-ended panel leads with the cloud: big enough to be the
    /// middle of the card, in a colour of its own rather than the resting
    /// grey, and awake. It was a 34pt grey cloud asleep, which read as the
    /// app having given up on the person it was asking to come back.
    func testTheTrialEndedPanelLeadsWithAnAwakeCloud() {
        XCTAssertEqual(LicenseBlockedView.face, .excited)
        XCTAssertNotEqual(LicenseBlockedView.face, .sleepy)
        XCTAssertNotEqual(LicenseBlockedView.tint, .resting, "a real Bloub colour, not grey")
        XCTAssertTrue((56...72).contains(LicenseBlockedView.cloudWidth),
                      "\(LicenseBlockedView.cloudWidth)pt is not the centre of the card")
    }

    /// The dictation strip is that panel in small, so it wears the same face.
    func testTheTrialEndedStripWearsThePanelsFace() {
        XCTAssertEqual(HoldNoticeCard.face(for: .noSubscription), LicenseBlockedView.face)
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
