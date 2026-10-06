import XCTest
@testable import AirlockCore

/// THE BUG THIS EXISTS FOR: a hold that captured nothing was always reported as
/// a broken microphone, because the only input to the decision was the peak
/// level. Sub-second holds never had a chance to capture anything — the input
/// had not finished starting — so the card sent people to Settings to replace
/// hardware that worked.
final class SilentCaptureTests: XCTestCase {
    /// A level that moved is not silence, however brief the window. There is
    /// nothing to explain and the card must not appear at all.
    func testAudioArrivedIsNotDiagnosedAtAll() {
        XCTAssertNil(SilentCapture.diagnose(peak: 0.08, listenedFor: 0.2))
        XCTAssertNil(SilentCapture.diagnose(peak: 0.08, listenedFor: 30))
        XCTAssertNil(SilentCapture.diagnose(peak: SilentCapture.silenceFloor, listenedFor: 0.5))
    }

    /// THE regression. Flat and short says nothing about the microphone.
    func testFlatAndShortIsNotBlamedOnTheMicrophone() {
        XCTAssertEqual(SilentCapture.diagnose(peak: 0, listenedFor: 0.5), .tooShort)
        XCTAssertEqual(SilentCapture.diagnose(peak: 0, listenedFor: 0.99), .tooShort)
    }

    /// And the other half: given a window long enough for any working input to
    /// have delivered, flat IS the microphone, and the card should still say so.
    func testFlatAndLongIsTheMicrophone() {
        XCTAssertEqual(SilentCapture.diagnose(peak: 0, listenedFor: 1.0), .inputProducedNothing)
        XCTAssertEqual(SilentCapture.diagnose(peak: 0, listenedFor: 8), .inputProducedNothing)
    }

    /// The observed failure, from the log that prompted the fix: a Bluetooth
    /// headset being used for playback delivers exactly zero for about a second
    /// while it switches profiles. Every one of these was previously reported as
    /// a hardware fault.
    func testTheBluetoothProfileSwitchIsNotAHardwareFault() {
        for window in stride(from: 0.4, to: SilentCapture.inputSettle, by: 0.1) {
            XCTAssertEqual(SilentCapture.diagnose(peak: 0, listenedFor: window), .tooShort,
                           "window=\(window)")
        }
    }

    /// The allowance has to be shorter than the hold ceiling it is measured
    /// inside, or every silent capture would read as "too short" and the
    /// microphone case would be unreachable.
    func testTheAllowanceIsReachable() {
        XCTAssertLessThan(SilentCapture.inputSettle, HoldGesture.maximumHold)
        XCTAssertGreaterThan(SilentCapture.inputSettle, HoldGesture.minimumHold,
                             "a window that always clears the allowance would never say 'too short'")
    }
}
