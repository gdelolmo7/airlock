import SwiftUI
import XCTest
@testable import AirlockApp

/// The five named motions (card C1). What each promises in words — Close
/// quicker than Open, Swap never wobbling, Nudge never looping — checked on
/// the same numbers the screen animates with.
final class NamedMotionTests: XCTestCase {

    private func peak(_ motion: Motion, reduceMotion: Bool) -> Double {
        stride(from: 0.0, through: 2.5, by: 1.0 / 120)
            .map { motion.progress(at: $0, reduceMotion: reduceMotion) }
            .max() ?? 0
    }

    func testThereAreFive() {
        XCTAssertEqual(Motion.allCases, [.open, .close, .swap, .confirm, .nudge])
    }

    func testCloseIsQuickerThanOpen() {
        XCTAssertLessThan(Motion.close.duration(reduceMotion: false), Motion.open.duration(reduceMotion: false))
        XCTAssertLessThan(Motion.close.duration(reduceMotion: true), Motion.open.duration(reduceMotion: true))
    }

    /// A panel bouncing on its way out, or a tab that wobbles, is noise.
    func testCloseAndSwapNeverOvershoot() {
        XCTAssertLessThanOrEqual(peak(.close, reduceMotion: false), 1.0005)
        XCTAssertLessThanOrEqual(peak(.swap, reduceMotion: false), 1.0005)
    }

    /// Open has a little life; Confirm is the one that settles visibly. Both
    /// small: a gate's buttons must not still be travelling under the pointer.
    func testOpenAndConfirmOvershootALittle() {
        let open = peak(.open, reduceMotion: false)
        XCTAssertGreaterThan(open, 1.005)
        XCTAssertLessThan(open, 1.05)
        XCTAssertGreaterThan(peak(.confirm, reduceMotion: false), open)
        XCTAssertLessThan(peak(.confirm, reduceMotion: false), 1.2)
    }

    func testEveryOneComesToRest() {
        for motion in Motion.allCases where motion != .nudge {
            for calm in [false, true] {
                let end = motion.duration(reduceMotion: calm)
                XCTAssertLessThan(end, 1.2, "\(motion) takes too long")
                XCTAssertEqual(motion.progress(at: end + 0.05, reduceMotion: calm), 1, accuracy: 0.01, "\(motion)")
            }
        }
    }

    /// The calm version is a plain fade: no spring, nothing past the end.
    func testCalmVersionsAreFadesThatNeverOvershoot() {
        for motion in Motion.allCases {
            XCTAssertEqual(motion.animation(reduceMotion: true), .easeInOut(duration: motion.calmDuration))
            XCTAssertLessThanOrEqual(peak(motion, reduceMotion: true), 1.0001, "\(motion)")
        }
    }

    // MARK: - Nudge

    func testNudgeRestsAfterAFewBeats() {
        let end = Motion.nudge.duration(reduceMotion: false)
        XCTAssertEqual(Motion.nudge.progress(at: end + 0.01, reduceMotion: false), 0)
        XCTAssertEqual(Motion.nudge.progress(at: end + 30, reduceMotion: false), 0)
        XCTAssertLessThan(end, 4, "a nudge that goes on is a loop by another name")
    }

    func testNudgeBeatsTheSaidNumberOfTimes() {
        var tops = 0
        var rising = false
        var last = 0.0
        for time in stride(from: 0.0, through: 5, by: 1.0 / 240) {
            let value = Motion.nudge.progress(at: time, reduceMotion: false)
            if value < last, rising { tops += 1 }
            rising = value > last
            last = value
        }
        XCTAssertEqual(tops, Motion.nudgeBeats)
    }

    func testCalmNudgeIsOneFade() {
        XCTAssertGreaterThan(Motion.nudge.progress(at: Motion.nudge.calmDuration / 2, reduceMotion: true), 0.9)
        XCTAssertEqual(Motion.nudge.progress(at: Motion.nudge.calmDuration + 0.01, reduceMotion: true), 0)
    }

    // MARK: - The guide reads them

    func testSteppedSpringTakesAMotionsTiming() {
        let spring = SteppedSpring(0, motion: .close)
        XCTAssertEqual(Double(spring.response), Motion.close.response)
        XCTAssertEqual(Double(spring.damping), Motion.close.damping)
    }
}
