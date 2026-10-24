import XCTest
@testable import AirlockCore

/// THE CRASH THIS EXISTS FOR: an ⌥ shortcut started the microphone and called
/// the hold off a tenth of a second later, and stopping the input that soon
/// crashed the app inside Core Audio. The stop now waits for the first buffer,
/// and never longer than an input may take to start delivering.
final class MicrophoneSettleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// THE regression: a shortcut's stop, before any audio has arrived, waits.
    func testAStopBeforeTheFirstBufferWaits() {
        for after in [0, 0.1, 0.25, 0.5, 0.75, 0.99] {
            XCTAssertFalse(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: false,
                                                    now: start.addingTimeInterval(after)),
                           "after \(after)s")
        }
    }

    /// Once the input has delivered, a stop goes ahead at once — however soon
    /// that is. A working microphone pays a buffer's length and no more.
    func testTheFirstBufferEndsTheWait() {
        for after in [0, 0.05, 0.1, 5] {
            XCTAssertTrue(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: true,
                                                   now: start.addingTimeInterval(after)),
                          "after \(after)s")
        }
    }

    /// An input that never delivers is let go at the ceiling, inclusive, so a
    /// dead microphone cannot keep the light on.
    func testAnInputThatNeverDeliversIsLetGoAtTheCeiling() {
        let ceiling = start.addingTimeInterval(MicrophoneSettle.ceiling)
        XCTAssertTrue(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: false, now: ceiling))
        XCTAssertTrue(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: false,
                                               now: ceiling.addingTimeInterval(30)))
    }

    /// The ceiling is bounded on both sides: long enough for the slow input
    /// `SilentCapture` allows for, short enough that a shortcut never holds
    /// the microphone for as long as a real hold.
    func testTheCeilingIsSensible() {
        XCTAssertEqual(MicrophoneSettle.ceiling, SilentCapture.inputSettle)
        XCTAssertLessThan(MicrophoneSettle.ceiling, HoldGesture.maximumHold)
        XCTAssertGreaterThan(MicrophoneSettle.ceiling, 0.25,
                             "below a buffer's length, a working input would be cut off before it delivered")
    }

    /// The ceiling a caller passes is the one used.
    func testAGivenCeilingIsUsed() {
        XCTAssertFalse(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: false,
                                                now: start.addingTimeInterval(0.0625), ceiling: 0.125))
        XCTAssertTrue(MicrophoneSettle.mayStop(startedAt: start, heardFirstBuffer: false,
                                               now: start.addingTimeInterval(0.125), ceiling: 0.125))
    }
}
