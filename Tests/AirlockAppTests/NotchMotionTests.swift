import SwiftUI
import XCTest
@testable import AirlockApp

/// The panel's own expand/collapse is the one animation the app does not draw —
/// it belongs to the vendored kit. Whether the *window* settles the way it
/// should is only visible by eye; what is testable is the decision handed to
/// the kit: Open growing, Close shrinking, calm under Reduce Motion.
final class NotchMotionTests: XCTestCase {

    func testOpeningIsOpenAndClosingIsClose() {
        let config = NotchMotion.transitionConfiguration(reduceMotion: false)
        XCTAssertEqual(config.openingAnimation, Motion.open.animation(reduceMotion: false))
        XCTAssertEqual(config.closingAnimation, Motion.close.animation(reduceMotion: false))
    }

    /// The kit has one conversion animation for both directions, so the
    /// controller says which way it is going: folding back into the compact
    /// island is a Close, and must be as quick as hiding.
    func testConversionFollowsTheDirection() {
        XCTAssertEqual(NotchMotion.transitionConfiguration(reduceMotion: false, growing: true).conversionAnimation,
                       Motion.open.animation(reduceMotion: false))
        XCTAssertEqual(NotchMotion.transitionConfiguration(reduceMotion: false, growing: false).conversionAnimation,
                       Motion.close.animation(reduceMotion: false))
    }

    /// Reduce Motion: every panel transition is the calm version, so nothing
    /// overshoots under a pointer already on its way to Approve or Deny.
    func testReduceMotionCalmsAllThree() {
        for growing in [true, false] {
            let config = NotchMotion.transitionConfiguration(reduceMotion: true, growing: growing)
            XCTAssertEqual(config.openingAnimation, Motion.open.animation(reduceMotion: true))
            XCTAssertEqual(config.closingAnimation, Motion.close.animation(reduceMotion: true))
            XCTAssertEqual(config.conversionAnimation,
                           (growing ? Motion.open : Motion.close).animation(reduceMotion: true))
        }
    }

    /// `skipIntermediateHides` is not a motion preference: without it,
    /// compact ↔ expanded routes through a hide and the island blinks out and
    /// back. Dropping it under Reduce Motion would ADD motion.
    func testIntermediateHidesStaySkippedInBothDirections() {
        XCTAssertTrue(NotchMotion.transitionConfiguration(reduceMotion: true).skipIntermediateHides)
        XCTAssertTrue(NotchMotion.transitionConfiguration(reduceMotion: false).skipIntermediateHides)
    }
}
