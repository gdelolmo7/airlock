import AVFoundation
import AirlockObjC
import XCTest

/// `ALExceptionCatcher` is all that stands between AVFAudio refusing and the
/// process dying somewhere else. 1.0.12 crashed twice that way: the raise came
/// during a hold, the crash a fraction of a second later in code that had
/// nothing to do with audio.
///
/// No test here touches audio hardware. The one real AVFAudio exception comes
/// from an engine in manual rendering mode, which renders offline — so nothing
/// opens a device and nothing asks for microphone permission.
@MainActor
final class ExceptionCatcherTests: XCTestCase {

    func testARaiseBecomesAnErrorCarryingItsNameAndReason() {
        XCTAssertThrowsError(try ALExceptionCatcher.catchException {
            raiseObjC("com.apple.coreaudio.avfaudio", reason: "required condition is false: nullptr == Tap()")
        }) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, ALExceptionErrorDomain)
            XCTAssertEqual(error.userInfo[ALExceptionNameKey] as? String, "com.apple.coreaudio.avfaudio")
            XCTAssertEqual(error.userInfo[ALExceptionReasonKey] as? String,
                           "required condition is false: nullptr == Tap()")
            XCTAssertEqual(error.localizedDescription, "required condition is false: nullptr == Tap()")
        }
    }

    /// A nil reason is legal. Building the error from it must not raise in
    /// turn, which would be the catcher crashing the process it is guarding.
    func testANilReasonStillReportsTheName() {
        XCTAssertThrowsError(try ALExceptionCatcher.catchException {
            raiseObjC("NoReasonGiven", reason: nil)
        }) { error in
            let error = error as NSError
            XCTAssertEqual(error.userInfo[ALExceptionNameKey] as? String, "NoReasonGiven")
            XCTAssertEqual(error.userInfo[ALExceptionReasonKey] as? String, "")
            XCTAssertEqual(error.localizedDescription, "NoReasonGiven")
        }
    }

    func testABlockThatDoesNotRaiseRunsOnceAndSucceeds() throws {
        var runs = 0
        try ALExceptionCatcher.catchException { runs += 1 }
        XCTAssertEqual(runs, 1)
    }

    /// AVFAudio's own exception rather than one made up here, from the call
    /// that raises most readily: a second tap on a bus that already has one.
    func testARealAVFAudioExceptionIsCaught() throws {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
        defer { mixer.removeTap(onBus: 0) }

        XCTAssertThrowsError(try ALExceptionCatcher.catchException {
            mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable _, _ in }
        }) { error in
            let error = error as NSError
            XCTAssertEqual(error.userInfo[ALExceptionNameKey] as? String, "com.apple.coreaudio.avfaudio")
            XCTAssertNotEqual(error.userInfo[ALExceptionReasonKey] as? String ?? "", "")
        }
    }

    /// The shape of the 1.0.12 crash, minus the crash. The raise happens in a
    /// main-actor job; the job ends; then a timer — not a Swift job, which is
    /// where both crashes landed — asks the runtime whether it is on the main
    /// actor. An exception that escaped the job left that question reading a
    /// job that no longer existed.
    func testTheMainActorStillAnswersAfterACaughtRaise() async {
        XCTAssertThrowsError(try ALExceptionCatcher.catchException {
            raiseObjC("com.apple.coreaudio.avfaudio", reason: "raised inside a main-actor job")
        })
        await Task.yield()
        let answered = await withCheckedContinuation { continuation in
            Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { continuation.resume(returning: true) }
            }
        }
        XCTAssertTrue(answered)
    }
}

/// Raises the way AVFAudio does — which Swift can do, and never catch.
private func raiseObjC(_ name: String, reason: String?) {
    NSException(name: NSExceptionName(name), reason: reason, userInfo: nil).raise()
}
