import SwiftUI
import XCTest
@testable import AirlockApp

/// Reduce Motion is an environment value, so the views that read it cannot be
/// unit-tested. The *decision* can be, and that is the half that has been wrong
/// in both directions: switching everything off removes feedback the guidance
/// asks for, and switching nothing off leaves perpetual motion running.
final class MotionTokenTests: XCTestCase {

    // MARK: - Perpetual effects go away entirely

    func testPerpetualIsNilUnderReduceMotion() {
        XCTAssertNil(Theme.perpetual(.easeInOut(duration: 0.7).repeatForever(), reduceMotion: true))
    }

    func testPerpetualIsUntouchedOtherwise() {
        let wanted = Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)
        XCTAssertEqual(Theme.perpetual(wanted, reduceMotion: false), wanted)
    }

    /// nil, not `.default`. A degraded animation is still an animation, and
    /// callers rely on having nothing to attach — see the note in `Theme`.
    func testPerpetualDoesNotDegradeToDefault() {
        XCTAssertNotEqual(Theme.perpetual(.linear, reduceMotion: true), Animation.default)
    }

    // MARK: - Named effects

    /// Following the pointer is feedback, not decoration: it has no calm
    /// version to fall back to, because it never needs one.
    func testPointerFeedbackIsQuickAndPlain() {
        XCTAssertEqual(MotionEffect.pointer, .easeOut(duration: 0.15))
    }

    /// A reading glides with the setting off and jumps with it on — small,
    /// frequent changes where movement says nothing the new value does not.
    func testReadingGoesUnderReduceMotion() {
        XCTAssertNil(MotionEffect.reading(reduceMotion: true))
        XCTAssertEqual(MotionEffect.reading(reduceMotion: false), .smooth(duration: 0.35))
    }

    /// The loops are what `perpetual` exists for: each one is switched off
    /// under Reduce Motion by passing through it.
    func testLoopsGoUnderReduceMotion() {
        let loops: [Animation] = [MotionEffect.pulse, MotionEffect.breathe,
                                  MotionEffect.waiting(dot: 1), MotionEffect.musicBars(bar: 2)]
        for loop in loops {
            XCTAssertNil(Theme.perpetual(loop, reduceMotion: true))
        }
    }

    /// Each dot and bar runs a beat behind the one before, so they travel
    /// rather than rising together.
    func testStaggeredLoopsAreStaggered() {
        XCTAssertNotEqual(MotionEffect.waiting(dot: 0), MotionEffect.waiting(dot: 1))
        XCTAssertNotEqual(MotionEffect.musicBars(bar: 0), MotionEffect.musicBars(bar: 1))
        XCTAssertNotEqual(MotionEffect.ringSweep(order: 0), MotionEffect.ringSweep(order: 1))
    }
}
